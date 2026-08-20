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

usage() {
    cat <<EOF
Usage:
  $0 certim|ctnode|all [--version v1.2.3] [--mirror [URL]]
  $0 uninstall [--purge]

Components:
  certim       - install the certim server
  ctnode       - install the ctnode agent
  all          - install both

Uninstall:
  uninstall    - remove installed components (auto-detected)
  --purge      - also remove data and config directories

Options:
  --version    - release version, default latest
  --mirror     - enable mirror https://ghfast.top (default: official GitHub)
  --mirror URL - custom mirror prefix
  -h, --help   - show this help

Online install:
  curl -fsSL https://raw.githubusercontent.com/Aceak/Certim-Release/main/install.sh \\
    | sudo bash -s -- certim [--mirror]
EOF
}

RELEASE_REPO="Aceak/Certim-Release"
VERSION="latest"
MIRROR=""     # 空 = 直连官方 GitHub
PURGE=0       # uninstall 时是否同时清除数据与配置目录

COMPONENT="${1:-}"
if [[ "${COMPONENT}" == "-h" || "${COMPONENT}" == "--help" ]]; then
    usage
    exit 0
fi
if [[ $# -gt 0 ]]; then
    shift
fi

if [[ $EUID -ne 0 ]]; then
    err "must run as root: sudo ./install.sh certim|ctnode|all [--version v1.2.3] [--mirror [URL]]"
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --version)
            [[ $# -ge 2 ]] || err "--version requires a value, e.g. --version v1.2.3"
            [[ -n "$2" ]] || err "--version value cannot be empty"
            VERSION="$2"
            shift 2
            ;;
        --mirror)
            shift
            if [[ $# -ge 1 && -n "$1" && "$1" != -* ]]; then
                MIRROR="$1"
                shift
            else
                MIRROR="https://ghfast.top"
            fi
            ;;
        --purge)
            PURGE=1
            shift
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

install_certim() {
    log "installing certim server..."

    ensure_assets

    local bin_path
    bin_path="$(download_binary certim)"

    install -v -m 0755 "${bin_path}" /usr/local/bin/certim
    log "certim → /usr/local/bin/certim"

    # 配置（已存在则跳过，保留用户配置）
    if [[ ! -f /etc/certim/config.yaml ]]; then
        mkdir -p /etc/certim
        cp "${CONFIG_DIR}/certim.example.yaml" /etc/certim/config.yaml
        log "config → /etc/certim/config.yaml"
        warn "edit /etc/certim/config.yaml to adjust defaults"
    else
        warn "/etc/certim/config.yaml exists, skipping"
    fi

    # 凭据目录（0700，存放 ACME 账户密钥与 DNS 凭据）
    mkdir -p /etc/certim/.credentials
    chmod 0700 /etc/certim/.credentials
    log "credentials dir → /etc/certim/.credentials (0700)"

    # 数据目录（systemd StateDirectory 也会自动创建）
    mkdir -p /var/lib/certim
    log "data dir → /var/lib/certim"

    install_unit certim

    echo ""
    log "certim installed. Start the service:"
    echo "  sudo systemctl enable --now certim"
    echo "  certim status"
}

install_ctnode() {
    log "installing ctnode agent..."

    ensure_assets

    local bin_path
    bin_path="$(download_binary ctnode)"

    install -v -m 0755 "${bin_path}" /usr/local/bin/ctnode
    log "ctnode → /usr/local/bin/ctnode"

    # 配置（已存在则跳过，保留用户配置）
    if [[ ! -f /etc/ctnode/config.yaml ]]; then
        mkdir -p /etc/ctnode
        cp "${CONFIG_DIR}/ctnode.example.yaml" /etc/ctnode/config.yaml
        log "config → /etc/ctnode/config.yaml"
        warn "edit /etc/ctnode/config.yaml and set server.url"
    else
        warn "/etc/ctnode/config.yaml exists, skipping"
    fi

    # 数据目录（systemd StateDirectory 也会自动创建，保存身份密钥与本地状态）
    mkdir -p /var/lib/ctnode
    log "data dir → /var/lib/ctnode"

    # 证书部署目录（<storage.root>/<certificate-name>/ 落盘位置）
    mkdir -p /etc/certim/certificates
    log "certificate dir → /etc/certim/certificates"

    install_unit ctnode

    echo ""
    log "ctnode installed. Enroll and start:"
    echo "  sudo ctnode enroll --token ctm_enroll_xxx --config /etc/ctnode/config.yaml"
    echo "  sudo systemctl enable --now ctnode"
    echo "  ctnode status --config /etc/ctnode/config.yaml"
}

uninstall_certim() {
    log "uninstalling certim server..."

    # 停止并禁用服务后移除单元
    if systemctl is-active certim &>/dev/null 2>&1; then
        systemctl stop certim || true
        log "stopped certim service"
    fi
    if systemctl is-enabled certim &>/dev/null 2>&1; then
        systemctl disable certim || true
        log "disabled certim service"
    fi
    rm -f /etc/systemd/system/certim.service
    if command -v systemctl &>/dev/null; then
        systemctl daemon-reload || true
    fi
    log "removed systemd unit"

    rm -f /usr/local/bin/certim
    log "removed /usr/local/bin/certim"

    rm -rf /run/certim
    log "removed runtime dir /run/certim"

    # 默认保留数据与配置，--purge 时一并清除
    if [[ "${PURGE}" -eq 1 ]]; then
        rm -rf /var/lib/certim /etc/certim
        log "purged data dir /var/lib/certim and config dir /etc/certim"
    else
        warn "keeping data dir /var/lib/certim and config dir /etc/certim"
        warn "to remove them too, run: $0 uninstall --purge"
    fi
}

uninstall_ctnode() {
    log "uninstalling ctnode agent..."

    # 停止并禁用服务后移除单元
    if systemctl is-active ctnode &>/dev/null 2>&1; then
        systemctl stop ctnode || true
        log "stopped ctnode service"
    fi
    if systemctl is-enabled ctnode &>/dev/null 2>&1; then
        systemctl disable ctnode || true
        log "disabled ctnode service"
    fi
    rm -f /etc/systemd/system/ctnode.service
    if command -v systemctl &>/dev/null; then
        systemctl daemon-reload || true
    fi
    log "removed systemd unit"

    rm -f /usr/local/bin/ctnode
    log "removed /usr/local/bin/ctnode"

    # 默认保留数据、配置与已部署证书，--purge 时一并清除
    if [[ "${PURGE}" -eq 1 ]]; then
        rm -rf /var/lib/ctnode /etc/ctnode /etc/certim/certificates
        log "purged data dir /var/lib/ctnode, config dir /etc/ctnode and certificate dir /etc/certim/certificates"
    else
        warn "keeping data dir /var/lib/ctnode, config dir /etc/ctnode and certificate dir /etc/certim/certificates"
        warn "to remove them too, run: $0 uninstall --purge"
    fi
}

case "${COMPONENT}" in
    certim)
        install_certim
        ;;
    ctnode)
        install_ctnode
        ;;
    all)
        install_certim
        echo ""
        install_ctnode
        ;;
    uninstall)
        found=0
        for component in certim ctnode; do
            if [[ -f "/usr/local/bin/${component}" ]]; then
                if [[ "${found}" -eq 1 ]]; then
                    echo ""
                fi
                "uninstall_${component}"
                found=1
            fi
        done
        if [[ "${found}" -eq 0 ]]; then
            warn "no installation found: no certim or ctnode in /usr/local/bin"
        fi
        ;;
    *)
        usage
        exit 1
        ;;
esac
