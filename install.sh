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
  ${SCRIPT_NAME} uninstall
  ${SCRIPT_NAME} purge

Components:
  certim       - install the certim server
  ctnode       - install the ctnode agent

Uninstall:
  uninstall    - remove installed components (auto-detected)
  purge        - uninstall and also remove data and config directories

Options:
  --mirror     - enable mirror https://ghfast.top (default: official GitHub)
  --mirror URL - custom mirror prefix
  -h, --help   - show this help

Online install:
  curl -fsSL https://raw.githubusercontent.com/Aceak/Certim-Release/main/install.sh \\
    | sudo bash -s -- certim|ctnode [--mirror]
EOF
}

RELEASE_REPO="Aceak/Certim-Release"
VERSION="latest"   # 固定安装最新发布版本
MIRROR=""          # 空 = 直连官方 GitHub
PURGE=0            # 卸载时是否同时清除数据与配置目录

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

if [[ $EUID -ne 0 ]]; then
    err "must run as root: sudo ${SCRIPT_NAME} certim|ctnode [--mirror [URL]]"
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
        trap 'rm -rf "${TMP_DIR}"' EXIT
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
    # 校验结果输出到 stderr，避免污染调用方的命令替换
    if ! (cd "${TMP_DIR}" && grep " ${file}$" checksums.txt | sha256sum -c - >&2); then
        err "checksum mismatch: ${file}, the mirror source may not be trustworthy"
    fi

    log "verifying binary"
    if ! "${TMP_DIR}/${file}" version >/dev/null 2>&1; then
        err "binary cannot execute: ${file}, download may be corrupted or incompatible"
    fi

    echo "${TMP_DIR}/${file}"
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
    bin_path="$(download_binary "${name}")"

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

    rm -f "/usr/local/bin/${name}"
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
