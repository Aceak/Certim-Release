#!/usr/bin/env bash
# =============================================================================
# Certim 安装脚本
# =============================================================================
# 用法:
#   sudo ./install.sh certim    # 安装 certim 服务端
#   sudo ./install.sh ctnode    # 安装 ctnode Agent
#   sudo ./install.sh all       # 同时安装
#
# 前置条件:
#   - 以 root 运行
#   - 已从 Release 仓库下载对应架构的二进制到 bin/ 目录
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${SCRIPT_DIR}/bin"
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

# ---- 权限检查 ----
if [[ $EUID -ne 0 ]]; then
    err "请以 root 运行: sudo ./install.sh certim|ctnode|all"
fi

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

# ---- 安装 certim ----
install_certim() {
    log "安装 certim 服务端..."

    local bin_file="certim-linux-${ARCH}"

    if [[ ! -f "${BIN_DIR}/${bin_file}" ]]; then
        err "找不到二进制: ${BIN_DIR}/${bin_file}"
    fi

    # 二进制
    install -v -m 0755 "${BIN_DIR}/${bin_file}" /usr/local/bin/certim
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

    # 数据目录
    mkdir -p /var/lib/certim
    log "数据目录 → /var/lib/certim"

    # 系统用户
    if ! id certim &>/dev/null; then
        useradd --system --home-dir /var/lib/certim --shell /usr/sbin/nologin certim
        log "创建系统用户 certim"
    fi
    chown -R certim:certim /var/lib/certim /etc/certim/.credentials
    chown certim:certim /etc/certim/config.yaml

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

    local bin_file="ctnode-linux-${ARCH}"

    if [[ ! -f "${BIN_DIR}/${bin_file}" ]]; then
        err "找不到二进制: ${BIN_DIR}/${bin_file}"
    fi

    # 二进制
    install -v -m 0755 "${BIN_DIR}/${bin_file}" /usr/local/bin/ctnode
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

    # 数据目录
    mkdir -p /var/lib/ctnode
    log "数据目录 → /var/lib/ctnode"

    # 证书部署目录
    mkdir -p /etc/certim/certificates
    log "证书目录 → /etc/certim/certificates"

    # 系统用户
    if ! id ctnode &>/dev/null; then
        useradd --system --home-dir /var/lib/ctnode --shell /usr/sbin/nologin ctnode
        log "创建系统用户 ctnode"
    fi
    chown -R ctnode:ctnode /var/lib/ctnode /etc/certim/certificates
    chown ctnode:ctnode /etc/ctnode/config.yaml

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

# ---- 入口 ----
case "${1:-}" in
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
    *)
        echo "用法: $0 certim|ctnode|all"
        echo ""
        echo "  certim  - 安装 certim 服务端"
        echo "  ctnode  - 安装 ctnode Agent"
        echo "  all     - 同时安装"
        exit 1
        ;;
esac
