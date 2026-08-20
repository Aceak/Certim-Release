#!/usr/bin/env bash
# =============================================================================
# Certim 安装脚本
# =============================================================================
# 用法:
#   sudo ./install.sh certim    # 安装 certim 服务端
#   sudo ./install.sh ctnode    # 安装 ctnode Agent
#   sudo ./install.sh all       # 同时安装
#
#   sudo ./install.sh uninstall [--purge]
#                               # 卸载本机已安装的组件（自动检测）
#                               # --purge 同时清除数据与配置目录
#
# 可选参数:
#   --version v1.2.3   指定发布版本，默认 latest
#   --mirror           启用下载镜像 https://ghfast.top（默认直连官方 GitHub）
#   --mirror URL       使用指定镜像前缀，例如 --mirror https://ghfast.top
#
# 脚本从 GitHub Releases 下载对应架构的二进制，校验 SHA-256 后安装到
# /usr/local/bin，并复制配置示例与 systemd 单元。
#
# 前置条件:
#   - 以 root 运行
#   - 系统已安装 curl 或 wget
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/configs"
SYSTEMD_DIR="${SCRIPT_DIR}/systemd"

# ---- 颜色 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[-]${NC} $*"; exit 1; }

# ---- 默认值 ----
RELEASE_REPO="Aceak/Certim-Release"
VERSION="latest"
MIRROR=""     # 空 = 直连官方 GitHub
PURGE=0       # uninstall 时是否同时清除数据与配置目录

# ---- 权限检查 ----
if [[ $EUID -ne 0 ]]; then
    err "请以 root 运行: sudo ./install.sh certim|ctnode|all [--version v1.2.3] [--mirror [URL]]"
fi

# ---- 参数解析 ----
COMPONENT="${1:-}"
if [[ $# -gt 0 ]]; then
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || err "--version 需要参数，例如 --version v1.2.3"
            [[ -n "$2" ]] || err "--version 值不能为空"
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
            err "未知参数: $1"
            ;;
    esac
done

# ---- 架构检测 ----
detect_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) err "不支持的架构: $arch" ;;
    esac
}

ARCH="$(detect_arch)"

# ---- 下载辅助 ----
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# 拼接下载 URL：可选镜像前缀 + GitHub Releases 地址
resolve_download_url() {
    local file="$1"
    local base="https://github.com/${RELEASE_REPO}/releases"
    if [[ -n "${MIRROR}" ]]; then
        echo "${MIRROR%/}/${base}/${VERSION}/download/${file}"
    else
        echo "${base}/${VERSION}/download/${file}"
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
        err "需要 curl 或 wget 下载二进制"
    fi
}

# 下载对应架构的二进制并校验 SHA-256，返回本地文件路径
download_binary() {
    local component="$1"
    local file="${component}-linux-${ARCH}"
    local url checksum_url

    url="$(resolve_download_url "${file}")"
    checksum_url="$(resolve_download_url "checksums.txt")"

    log "下载 ${file} (${VERSION})"
    log "URL: ${url}"
    if ! download_file "${url}" "${TMP_DIR}/${file}"; then
        err "下载失败: ${file}，可更换镜像重试: --mirror <URL>"
    fi

    log "下载 checksums.txt"
    if ! download_file "${checksum_url}" "${TMP_DIR}/checksums.txt"; then
        err "下载校验文件失败，可更换镜像重试: --mirror <URL>"
    fi

    log "校验 SHA-256"
    if ! (cd "${TMP_DIR}" && grep " ${file}$" checksums.txt | sha256sum -c -); then
        err "校验失败: ${file}，请确认镜像来源可信后重试"
    fi

    echo "${TMP_DIR}/${file}"
}

# ---- 安装 certim ----
install_certim() {
    log "安装 certim 服务端..."

    local bin_path
    bin_path="$(download_binary certim)"

    # 二进制
    install -v -m 0755 "${bin_path}" /usr/local/bin/certim
    log "certim → /usr/local/bin/certim"

    # 配置目录
    if [[ ! -f /etc/certim/config.yaml ]]; then
        mkdir -p /etc/certim
        cp "${CONFIG_DIR}/certim.example.yaml" /etc/certim/config.yaml
        log "配置 → /etc/certim/config.yaml"
        warn "请编辑 /etc/certim/config.yaml 修改默认值"
    else
        warn "/etc/certim/config.yaml 已存在，跳过"
    fi

    # 凭据目录
    mkdir -p /etc/certim/.credentials
    chmod 0700 /etc/certim/.credentials
    log "凭据目录 → /etc/certim/.credentials (0700)"

    # 数据目录（systemd StateDirectory 也会自动创建）
    mkdir -p /var/lib/certim
    log "数据目录 → /var/lib/certim"

    # systemd
    cp "${SYSTEMD_DIR}/certim.service" /etc/systemd/system/
    systemctl daemon-reload
    log "systemd 单元 → /etc/systemd/system/certim.service"

    # 启动提示
    echo ""
    log "certim 安装完成。启动服务:"
    echo "  sudo systemctl enable --now certim"
    echo "  certim status"
}

# ---- 安装 ctnode ----
install_ctnode() {
    log "安装 ctnode Agent..."

    local bin_path
    bin_path="$(download_binary ctnode)"

    # 二进制
    install -v -m 0755 "${bin_path}" /usr/local/bin/ctnode
    log "ctnode → /usr/local/bin/ctnode"

    # 配置目录
    if [[ ! -f /etc/ctnode/config.yaml ]]; then
        mkdir -p /etc/ctnode
        cp "${CONFIG_DIR}/ctnode.example.yaml" /etc/ctnode/config.yaml
        log "配置 → /etc/ctnode/config.yaml"
        warn "请编辑 /etc/ctnode/config.yaml 填写 server.url"
    else
        warn "/etc/ctnode/config.yaml 已存在，跳过"
    fi

    # 数据目录（systemd StateDirectory 也会自动创建）
    mkdir -p /var/lib/ctnode
    log "数据目录 → /var/lib/ctnode"

    # 证书部署目录
    mkdir -p /etc/certim/certificates
    log "证书目录 → /etc/certim/certificates"

    # systemd
    cp "${SYSTEMD_DIR}/ctnode.service" /etc/systemd/system/
    systemctl daemon-reload
    log "systemd 单元 → /etc/systemd/system/ctnode.service"

    # 注册提示
    echo ""
    log "ctnode 安装完成。注册并启动:"
    echo "  sudo ctnode enroll --token ctm_enroll_xxx --config /etc/ctnode/config.yaml"
    echo "  sudo systemctl enable --now ctnode"
    echo "  ctnode status --config /etc/ctnode/config.yaml"
}

# ---- 卸载 certim ----
uninstall_certim() {
    log "卸载 certim 服务端..."

    if systemctl is-active certim &>/dev/null 2>&1; then
        systemctl stop certim || true
        log "已停止 certim 服务"
    fi
    if systemctl is-enabled certim &>/dev/null 2>&1; then
        systemctl disable certim || true
        log "已禁用 certim 服务"
    fi
    rm -f /etc/systemd/system/certim.service
    systemctl daemon-reload
    log "已移除 systemd 单元"

    rm -f /usr/local/bin/certim
    log "已移除 /usr/local/bin/certim"

    rm -rf /run/certim
    log "已移除运行目录 /run/certim"

    if [[ "${PURGE}" -eq 1 ]]; then
        rm -rf /var/lib/certim /etc/certim
        log "已清除数据目录 /var/lib/certim 和配置目录 /etc/certim"
    else
        warn "保留数据目录 /var/lib/certim 和配置目录 /etc/certim"
        warn "如需彻底清除，使用: $0 uninstall --purge"
    fi
}

# ---- 卸载 ctnode ----
uninstall_ctnode() {
    log "卸载 ctnode Agent..."

    if systemctl is-active ctnode &>/dev/null 2>&1; then
        systemctl stop ctnode || true
        log "已停止 ctnode 服务"
    fi
    if systemctl is-enabled ctnode &>/dev/null 2>&1; then
        systemctl disable ctnode || true
        log "已禁用 ctnode 服务"
    fi
    rm -f /etc/systemd/system/ctnode.service
    systemctl daemon-reload
    log "已移除 systemd 单元"

    rm -f /usr/local/bin/ctnode
    log "已移除 /usr/local/bin/ctnode"

    if [[ "${PURGE}" -eq 1 ]]; then
        rm -rf /var/lib/ctnode /etc/ctnode /etc/certim/certificates
        log "已清除数据目录 /var/lib/ctnode、配置目录 /etc/ctnode 和证书目录 /etc/certim/certificates"
    else
        warn "保留数据目录 /var/lib/ctnode、配置目录 /etc/ctnode 和证书目录 /etc/certim/certificates"
        warn "如需彻底清除，使用: $0 uninstall --purge"
    fi
}

# ---- 入口 ----
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
            warn "未检测到安装：/usr/local/bin 下没有 certim 或 ctnode"
        fi
        ;;
    *)
        echo "用法:"
        echo "  $0 certim|ctnode|all [--version v1.2.3] [--mirror [URL]]"
        echo "  $0 uninstall [--purge]"
        echo ""
        echo "安装目标:"
        echo "  certim      - 安装 certim 服务端"
        echo "  ctnode      - 安装 ctnode Agent"
        echo "  all         - 同时安装"
        echo ""
        echo "卸载:"
        echo "  uninstall   - 移除本机已安装组件的二进制和 systemd 单元（自动检测）"
        echo "  --purge     - 卸载时同时清除数据与配置目录"
        echo ""
        echo "可选参数:"
        echo "  --version   - 指定发布版本，默认 latest"
        echo "  --mirror    - 启用下载镜像 https://ghfast.top（默认直连官方 GitHub）"
        echo "  --mirror URL - 使用指定镜像前缀"
        exit 1
        ;;
esac
