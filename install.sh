#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/configs"
SYSTEMD_DIR="${SCRIPT_DIR}/systemd"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }
err()  { echo -e "${RED}[-]${NC} $*" >&2; exit 1; }

# 管道执行（curl | bash）时 $0 是 bash，usage 中显示 install.sh
SCRIPT_NAME="$(basename "${0}")"
[[ "${SCRIPT_NAME}" == "bash" ]] && SCRIPT_NAME="install.sh"

usage() {
    cat <<EOF
Usage:
  ${SCRIPT_NAME} certim|ctnode [--mirror [URL]]
  ${SCRIPT_NAME} upgrade [certim|ctnode] [--mirror [URL]]
  ${SCRIPT_NAME} uninstall
  ${SCRIPT_NAME} purge

Components:
  certim       - install the certim server
  ctnode       - install the ctnode agent

Upgrade:
  upgrade       - upgrade all installed components to the latest release
  upgrade NAME  - upgrade certim or ctnode only

Uninstall:
  uninstall    - remove installed components (auto-detected)
  purge        - uninstall and also remove data and config directories

Options:
  --mirror     - enable mirror https://ghfast.top (default: official GitHub)
  --mirror URL - custom mirror prefix
  -h, --help   - show this help

Online install:
  curl -fsSL https://raw.githubusercontent.com/Aceak/Certim-Release/main/install.sh \\
    | sudo bash -s -- certim|ctnode|upgrade [--mirror]
EOF
}

RELEASE_REPO="Aceak/Certim-Release"
VERSION="latest"   # 固定安装最新发布版本
MIRROR=""          # 空 = 直连官方 GitHub
PURGE=0            # 卸载时是否同时清除数据与配置目录

UPGRADE_COMPONENT=""  # upgrade 时可选指定的组件;空 = 自动检测已安装组件
COMPAT_FILE=""        # 兼容性规则文件路径;空 = 不可用(跳过兼容性检查)
BIN_PATH=""           # download_binary 下载的二进制路径(见 download_binary)

COMPONENT="${1:-}"
if [[ "${COMPONENT}" == "-h" || "${COMPONENT}" == "--help" ]]; then
    usage
    exit 0
fi
# purge 命令等价于 uninstall 并清除数据与配置
if [[ "${COMPONENT}" == "purge" ]]; then
    COMPONENT="uninstall"
    PURGE=1
fi
if [[ $# -gt 0 ]]; then
    shift
fi
# upgrade 允许可选的组件参数: install.sh upgrade [certim|ctnode] [--mirror [URL]]
if [[ "${COMPONENT}" == "upgrade" && $# -gt 0 && "$1" != -* ]]; then
    UPGRADE_COMPONENT="$1"
    shift
fi

if [[ $EUID -ne 0 ]]; then
    err "must run as root: sudo ${SCRIPT_NAME} certim|ctnode|upgrade [--mirror [URL]]"
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --mirror)
            shift
            if [[ $# -ge 1 && -n "$1" && "$1" != -* ]]; then
                [[ "$1" =~ ^https?:// ]] || err "mirror must start with http:// or https://"
                MIRROR="$1"
                shift
            else
                MIRROR="https://ghfast.top"
            fi
            ;;
        *)
            err "unknown option: $1"
            ;;
    esac
done

detect_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) err "unsupported architecture: $arch" ;;
    esac
}

ARCH="$(detect_arch)"

RAW_BASE="https://raw.githubusercontent.com/${RELEASE_REPO}/main"
TMP_DIR=""

# 按需创建临时目录并注册退出清理
ensure_tmp_dir() {
    if [[ -z "${TMP_DIR}" ]]; then
        TMP_DIR="$(mktemp -d)"
        # 命令替换等子 shell 会继承并执行 EXIT trap;用 BASHPID 守卫
        # 确保只有主进程退出时才清理临时目录
        trap '[[ "${BASHPID}" == "$$" ]] && rm -rf "${TMP_DIR}"' EXIT
    fi
}

# 拼接发布下载 URL：可选镜像前缀 + GitHub Releases 地址
resolve_download_url() {
    local file="$1"
    local base="https://github.com/${RELEASE_REPO}/releases"
    if [[ -n "${MIRROR}" ]]; then
        echo "${MIRROR%/}/${base}/${VERSION}/download/${file}"
    else
        echo "${base}/${VERSION}/download/${file}"
    fi
}

# 拼接仓库原始文件 URL：可选镜像前缀 + raw.githubusercontent.com 地址
resolve_raw_url() {
    local path="$1"
    if [[ -n "${MIRROR}" ]]; then
        echo "${MIRROR%/}/${RAW_BASE}/${path}"
    else
        echo "${RAW_BASE}/${path}"
    fi
}

# 下载文件，失败时返回非零
download_file() {
    local url="$1"
    local dest="$2"

    if command -v curl &>/dev/null; then
        curl -fsSL --connect-timeout 15 --max-time 300 --retry 3 "$url" -o "$dest"
    elif command -v wget &>/dev/null; then
        wget -q --timeout=15 --tries=3 -O "$dest" "$url"
    else
        err "curl or wget is required"
    fi
}

# 本地仓库目录存在时直接使用；在线安装（curl | bash）时从 main 分支下载。
ensure_assets() {
    if [[ -d "${CONFIG_DIR}" && -d "${SYSTEMD_DIR}" ]]; then
        return 0
    fi

    ensure_tmp_dir
    CONFIG_DIR="${TMP_DIR}/configs"
    SYSTEMD_DIR="${TMP_DIR}/systemd"
    mkdir -p "${CONFIG_DIR}" "${SYSTEMD_DIR}"

    log "configs/systemd not found locally, downloading deployment assets..."
    local src url
    for src in \
        configs/certim.example.yaml \
        configs/ctnode.example.yaml \
        systemd/certim.service \
        systemd/ctnode.service
    do
        url="$(resolve_raw_url "${src}")"
        if ! download_file "${url}" "${TMP_DIR}/${src}"; then
            err "failed to download asset: ${src}, try another mirror: --mirror <URL>"
        fi
        log "downloaded ${src}"
    done
}

# 下载对应架构的二进制，校验 SHA-256 并验证可执行，返回本地文件路径
download_binary() {
    local component="$1"
    local file="${component}-linux-${ARCH}"
    local url checksum_url

    ensure_tmp_dir

    url="$(resolve_download_url "${file}")"
    checksum_url="$(resolve_download_url "checksums.txt")"

    log "downloading ${file} (${VERSION})"
    log "URL: ${url}"
    if ! download_file "${url}" "${TMP_DIR}/${file}"; then
        err "download failed: ${file}, try another mirror: --mirror <URL>"
    fi

    log "downloading checksums.txt"
    if ! download_file "${checksum_url}" "${TMP_DIR}/checksums.txt"; then
        err "failed to download checksums.txt, try another mirror: --mirror <URL>"
    fi

    log "verifying SHA-256"
    # --quiet：成功无输出，失败时 sha256sum 自行打印详情
    if ! (cd "${TMP_DIR}" && grep " ${file}$" checksums.txt | sha256sum -c --quiet -); then
        err "checksum mismatch: ${file}, the mirror source may not be trustworthy"
    fi

    # curl/wget 下载的文件不带执行权限，先 chmod 再执行校验
    chmod 0755 "${TMP_DIR}/${file}"
    log "verifying binary"
    if ! "${TMP_DIR}/${file}" version >/dev/null 2>&1; then
        err "binary cannot execute: ${file}, download may be corrupted or incompatible"
    fi

    # 调用方必须以普通调用(而非命令替换)使用本函数: 命令替换子 shell 中
    # 创建的 TMP_DIR 不会带回父 shell, 且子 shell 退出时可能触发 trap 清理。
    # 路径同时写入全局变量 BIN_PATH, 供调用方读取。
    BIN_PATH="${TMP_DIR}/${file}"
    echo "${BIN_PATH}"
}

# 从 "<name> vX.Y.Z" 形式输出中提取版本号, 输出无 v 前缀的版本;不可解析时输出 unknown
parse_version() {
    local out="$1"
    if [[ "${out}" =~ ^[A-Za-z0-9_-]+[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "unknown"
    fi
}

# 读取已安装二进制的版本号;二进制缺失时返回非零
installed_version() {
    local name="$1" out
    [[ -x "/usr/local/bin/${name}" ]] || return 1
    out="$("/usr/local/bin/${name}" version 2>/dev/null || true)"
    parse_version "${out}"
}

# 语义化版本比较: 输出 -1(a<b) / 0(a=b) / 1(a>b)。
# 预发布版本(-suffix)低于对应正式版, 预发布标识之间按字符串序比较。
ver_cmp() {
    awk -v x="$1" -v y="$2" '
        function splitver(v, a,    p, n, i, pre) {
            # 先取出预发布标识再 split: split() 会清空数组, 先写入 a[4] 会丢失
            pre = ""
            p = index(v, "-")
            if (p > 0) {
                pre = substr(v, p + 1)
                v = substr(v, 1, p - 1)
            }
            n = split(v, a, "\\.")
            for (i = n + 1; i <= 3; i++) { a[i] = 0 }
            for (i = 1; i <= 3; i++) { a[i] = (a[i] ~ /^[0-9]+$/) ? a[i] + 0 : 0 }
            a[4] = pre
        }
        BEGIN {
            splitver(x, A)
            splitver(y, B)
            for (i = 1; i <= 3; i++) {
                if (A[i] > B[i]) { print 1; exit }
                if (A[i] < B[i]) { print -1; exit }
            }
            if (A[4] == B[4]) { print 0; exit }
            if (A[4] == "")   { print 1; exit }
            if (B[4] == "")   { print -1; exit }
            if (A[4] > B[4])  { print 1; exit }
            print -1
        }'
}

# 判断 version 是否满足约束算子(>= <= == > <);version 为 unknown 时返回 2(无法判断)
version_match() {
    local version="$1" op="$2" target="$3" cmp
    [[ "${version}" != "unknown" ]] || return 2
    cmp="$(ver_cmp "${version}" "${target}")"
    case "${op}" in
        ">=") [[ "${cmp}" -ge 0 ]] ;;
        ">")  [[ "${cmp}" -gt 0 ]] ;;
        "<=") [[ "${cmp}" -le 0 ]] ;;
        "<")  [[ "${cmp}" -lt 0 ]] ;;
        "==") [[ "${cmp}" -eq 0 ]] ;;
        *)    return 2 ;;
    esac
}

# 兼容性规则文件: 本地仓库存在则直接使用;在线安装时从 main 分支下载。
# 下载失败 fail-open: 告警后跳过兼容性检查, 升级不因网络波动被卡死。
ensure_compat_file() {
    if [[ -f "${SCRIPT_DIR}/compatibility.conf" ]]; then
        COMPAT_FILE="${SCRIPT_DIR}/compatibility.conf"
        return 0
    fi
    ensure_tmp_dir
    if download_file "$(resolve_raw_url "compatibility.conf")" "${TMP_DIR}/compatibility.conf"; then
        COMPAT_FILE="${TMP_DIR}/compatibility.conf"
        return 0
    fi
    COMPAT_FILE=""
    warn "compatibility.conf unavailable, skipping compatibility checks"
    return 1
}

# 依据 compatibility.conf 检查升级兼容性, 必须在任何文件写入之前调用。
# - requires: 目标版本满足约束时, 本机 <dep> 须满足其约束, 否则阻断;
#   <dep> 未安装或版本不可解析时无法本机校验, 仅提示。
# - step: 当前版本低于 via 时不允许直接升级到满足约束的版本, 阻断并提示分两步。
# - matrix: 两个组件同机且版本分别落入约束区间时告警(不阻断)。
apply_compat_rules() {
    local component="$1" from="$2" to="$3"
    local -a words
    local kind pkg op target dep dep_op dep_ver via_ver pkg_ver dep_ver_cur

    while read -r -a words; do
        [[ ${#words[@]} -gt 0 && "${words[0]}" != \#* ]] || continue

        kind="${words[0]}"
        case "${kind}" in
            requires|matrix)
                [[ ${#words[@]} -eq 7 ]] || {
                    warn "compatibility.conf: malformed ${kind} rule, skipping: ${words[*]}"
                    continue
                }
                pkg="${words[1]}"; op="${words[2]}"; target="${words[3]}"
                dep="${words[4]}"; dep_op="${words[5]}"; dep_ver="${words[6]}"
                ;;
            step)
                [[ ${#words[@]} -eq 6 && "${words[4]}" == "via" ]] || {
                    warn "compatibility.conf: malformed step rule, skipping: ${words[*]}"
                    continue
                }
                pkg="${words[1]}"; op="${words[2]}"; target="${words[3]}"
                via_ver="${words[5]}"
                ;;
            *)
                warn "compatibility.conf: unknown rule kind '${kind}', skipping"
                continue
                ;;
        esac

        # requires/step 只处理与本次升级组件相关、且目标版本落入约束区间的规则
        if [[ "${kind}" != "matrix" ]]; then
            [[ "${pkg}" == "${component}" ]] || continue
            if ! version_match "${to}" "${op}" "${target}"; then
                continue
            fi
        fi

        case "${kind}" in
            requires)
                dep_ver_cur="$(installed_version "${dep}" || true)"
                if [[ -z "${dep_ver_cur}" ]]; then
                    warn "rule: ${component} ${op} ${target} requires ${dep} ${dep_op} ${dep_ver}"
                    warn "${dep} is not installed on this host, verify the remote ${dep} version manually"
                    continue
                fi
                if [[ "${dep_ver_cur}" == "unknown" ]]; then
                    warn "rule: ${component} ${op} ${target} requires ${dep} ${dep_op} ${dep_ver}; installed ${dep} version unknown, proceeding"
                    continue
                fi
                if ! version_match "${dep_ver_cur}" "${dep_op}" "${dep_ver}"; then
                    err "compatibility check failed: upgrading ${component} to ${to} requires ${dep} ${dep_op} ${dep_ver} (installed: ${dep_ver_cur}); upgrade ${dep} first"
                fi
                ;;
            step)
                if [[ "${from}" == "unknown" ]]; then
                    warn "rule: direct upgrade to ${component} ${op} ${target} requires ${via_ver} first; current version unknown, proceeding"
                    continue
                fi
                if [[ "$(ver_cmp "${from}" "${via_ver}")" -lt 0 ]]; then
                    err "compatibility check failed: cannot upgrade ${component} ${from} directly to ${to}; upgrade to ${via_ver} first"
                fi
                ;;
            matrix)
                # 两侧版本分别落入约束区间即告警;被升级组件取目标版本, 其余取已装版本
                if [[ "${pkg}" == "${component}" ]]; then
                    pkg_ver="${to}"
                else
                    pkg_ver="$(installed_version "${pkg}" || true)"
                fi
                if [[ "${dep}" == "${component}" ]]; then
                    dep_ver_cur="${to}"
                else
                    dep_ver_cur="$(installed_version "${dep}" || true)"
                fi
                [[ -n "${pkg_ver}" && -n "${dep_ver_cur}" ]] || continue
                if version_match "${pkg_ver}" "${op}" "${target}" &&
                   version_match "${dep_ver_cur}" "${dep_op}" "${dep_ver}"; then
                    warn "compatibility matrix: ${pkg} ${pkg_ver} is not compatible with ${dep} ${dep_ver_cur} on this host"
                fi
                ;;
        esac
    done < "${COMPAT_FILE}"
}

# 升级单个组件: 版本比较 → 兼容性检查 → 备份替换 → 单元刷新 → 服务重启。
# 配置与数据目录保持不变;SQLite 迁移由新版二进制首次启动时自动完成。
upgrade_component() {
    local name="$1"
    local from to bin_path cmp

    from="$(installed_version "${name}" || true)"
    if [[ -z "${from}" ]]; then
        warn "${name} not found in /usr/local/bin, run: ${SCRIPT_NAME} ${name} to install"
        return 0
    fi

    log "upgrading ${name}..."
    ensure_assets
    download_binary "${name}" >/dev/null
    bin_path="${BIN_PATH}"
    to="$(parse_version "$("${bin_path}" version)")"

    if [[ "${from}" != "unknown" && "${to}" != "unknown" ]]; then
        cmp="$(ver_cmp "${from}" "${to}")"
        if [[ "${cmp}" -ge 0 ]]; then
            log "${name} ${from} is already up to date (latest: ${to}), skipping"
            return 0
        fi
    fi

    # 兼容性检查必须发生在任何文件写入之前
    if ensure_compat_file; then
        apply_compat_rules "${name}" "${from}" "${to}"
    fi

    # 替换前备份旧二进制, 升级失败时可用 <name>.old 手动回滚
    rm -f "/usr/local/bin/${name}.old"
    cp -p "/usr/local/bin/${name}" "/usr/local/bin/${name}.old"
    install -m 0755 "${bin_path}" "/usr/local/bin/${name}"
    log "${name} ${from} → ${to} (/usr/local/bin/${name})"
    log "previous binary kept at /usr/local/bin/${name}.old"

    install_unit "${name}"

    # 服务处于运行状态时重启以加载新二进制, 否则保持停止
    if command -v systemctl &>/dev/null && systemctl is-active "${name}" &>/dev/null 2>&1; then
        if systemctl restart "${name}"; then
            log "${name} service restarted"
        else
            warn "${name} service failed to restart"
            warn "restore with: sudo cp /usr/local/bin/${name}.old /usr/local/bin/${name} && sudo systemctl restart ${name}"
            return 1
        fi
    else
        warn "${name} service is not running, start it with: sudo systemctl start ${name}"
    fi

    echo ""
    log "${name} upgraded to ${to}"
}

# 复制 systemd 单元并重载守护进程，systemctl 不可用时跳过
install_unit() {
    local name="$1"

    if ! command -v systemctl &>/dev/null; then
        warn "systemctl not found, skipping systemd unit installation"
        return 0
    fi

    cp "${SYSTEMD_DIR}/${name}.service" /etc/systemd/system/
    systemctl daemon-reload || warn "systemctl daemon-reload failed"
    log "systemd unit → /etc/systemd/system/${name}.service"
}

# 安装组件：下载并校验二进制，复制配置示例、组件目录和 systemd 单元
install_component() {
    local name="$1"
    local config_hint=" to adjust defaults"
    local bin_path

    [[ "${name}" == "ctnode" ]] && config_hint=" and set server.url"

    log "installing ${name}..."
    ensure_assets
    download_binary "${name}" >/dev/null
    bin_path="${BIN_PATH}"

    install -v -m 0755 "${bin_path}" "/usr/local/bin/${name}"
    log "${name} → /usr/local/bin/${name}"

    # 配置（已存在则跳过，保留用户配置）
    if [[ ! -f "/etc/${name}/config.yaml" ]]; then
        mkdir -p "/etc/${name}"
        cp "${CONFIG_DIR}/${name}.example.yaml" "/etc/${name}/config.yaml"
        log "config → /etc/${name}/config.yaml"
        warn "edit /etc/${name}/config.yaml${config_hint}"
    else
        warn "/etc/${name}/config.yaml exists, skipping"
    fi

    # 数据目录（systemd StateDirectory 也会自动创建）
    mkdir -p "/var/lib/${name}"
    log "data dir → /var/lib/${name}"

    case "${name}" in
        certim)
            # 凭据目录（0700，存放 ACME 账户密钥与 DNS 凭据）
            mkdir -p /etc/certim/.credentials
            chmod 0700 /etc/certim/.credentials
            log "credentials dir → /etc/certim/.credentials (0700)"
            ;;
        ctnode)
            # 证书部署目录（<storage.root>/<certificate-name>/ 落盘位置）
            mkdir -p /etc/certim/certificates
            log "certificate dir → /etc/certim/certificates"
            ;;
    esac

    install_unit "${name}"

    echo ""
    case "${name}" in
        certim)
            log "certim installed. Start the service:"
            echo "  sudo systemctl enable --now certim"
            echo "  certim status"
            ;;
        ctnode)
            log "ctnode installed. Enroll and start:"
            echo "  sudo ctnode enroll --token ctm_enroll_xxx --config /etc/ctnode/config.yaml"
            echo "  sudo systemctl enable --now ctnode"
            echo "  ctnode status --config /etc/ctnode/config.yaml"
            ;;
    esac
}

# 卸载组件：停止服务并移除二进制与 systemd 单元；purge 时清除数据、配置
# 和早期版本创建的系统用户
uninstall_component() {
    local name="$1"
    local -a purge_dirs=("/var/lib/${name}" "/etc/${name}")

    [[ "${name}" == "ctnode" ]] && purge_dirs+=("/etc/certim/certificates")

    log "uninstalling ${name}..."

    if systemctl is-active "${name}" &>/dev/null 2>&1; then
        systemctl stop "${name}" || true
        log "stopped ${name} service"
    fi
    if systemctl is-enabled "${name}" &>/dev/null 2>&1; then
        systemctl disable "${name}" || true
        log "disabled ${name} service"
    fi
    rm -f "/etc/systemd/system/${name}.service"
    if command -v systemctl &>/dev/null; then
        systemctl daemon-reload || true
    fi
    log "removed systemd unit"

    rm -f "/usr/local/bin/${name}" "/usr/local/bin/${name}.old"
    log "removed /usr/local/bin/${name}"

    # certim 的运行目录（tmpfs）随卸载清除
    if [[ "${name}" == "certim" ]]; then
        rm -rf /run/certim
        log "removed runtime dir /run/certim"
    fi

    if [[ "${PURGE}" -eq 1 ]]; then
        rm -rf "${purge_dirs[@]}"
        log "purged ${purge_dirs[*]}"
        if id "${name}" &>/dev/null 2>&1; then
            userdel "${name}" 2>/dev/null || warn "failed to remove legacy user ${name}"
            log "removed legacy user ${name}"
        fi
    else
        warn "keeping ${purge_dirs[*]}"
        warn "to remove them too, run: ${SCRIPT_NAME} purge"
    fi
}

case "${COMPONENT}" in
    certim|ctnode)
        install_component "${COMPONENT}"
        ;;
    upgrade)
        if [[ -n "${UPGRADE_COMPONENT}" ]]; then
            case "${UPGRADE_COMPONENT}" in
                certim|ctnode) upgrade_component "${UPGRADE_COMPONENT}" ;;
                *) err "unknown component: ${UPGRADE_COMPONENT}" ;;
            esac
        else
            found=0
            for component in certim ctnode; do
                if [[ -x "/usr/local/bin/${component}" ]]; then
                    if [[ "${found}" -eq 1 ]]; then
                        echo ""
                    fi
                    # 单个组件升级失败不中断其余组件(错误已由 upgrade_component 输出)
                    upgrade_component "${component}" || true
                    found=1
                fi
            done
            if [[ "${found}" -eq 0 ]]; then
                warn "no installation found: nothing to upgrade"
            fi
        fi
        ;;
    uninstall)
        if [[ "${PURGE}" -eq 1 ]]; then
            # 无条件深度清理，覆盖早期版本的部分残留
            uninstall_component certim
            echo ""
            uninstall_component ctnode
        else
            found=0
            for component in certim ctnode; do
                if [[ -f "/usr/local/bin/${component}" ]]; then
                    if [[ "${found}" -eq 1 ]]; then
                        echo ""
                    fi
                    uninstall_component "${component}"
                    found=1
                fi
            done
            if [[ "${found}" -eq 0 ]]; then
                warn "no installation found: no certim or ctnode in /usr/local/bin"
            fi
        fi
        ;;
    *)
        usage
        exit 1
        ;;
esac
