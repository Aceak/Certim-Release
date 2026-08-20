# Certim Release

Certim 生产部署资源仓库。预编译二进制通过 GitHub Releases 发布，本仓库提供
systemd 单元、配置示例、Nginx 反代示例和安装脚本，让生产节点快速搭建
Certim 服务端和 ctnode Agent。

## 仓库内容

```text
Release/
├── README.md                        # 本文件
├── install.sh                       # 一键安装/卸载脚本
├── configs/
│   ├── certim.example.yaml          # certim 服务端配置示例
│   └── ctnode.example.yaml          # ctnode Agent 配置示例
├── systemd/
│   ├── certim.service               # certim 服务端 systemd 单元
│   └── ctnode.service               # ctnode Agent systemd 单元
└── nginx/
    └── nginx-certim.example.conf    # Agent API 反向代理示例
```

发布二进制通过 [GitHub Releases](../../releases) 提供，下载后放入本仓库的 `bin/`
目录即可配合 `install.sh` 使用。

## 快速安装

### 证书管理节点（运行 certim serve）

```bash
# 从 GitHub Releases 下载二进制到 bin/（手动安装时使用）
sudo cp bin/certim-linux-amd64 /usr/local/bin/certim
sudo chmod 0755 /usr/local/bin/certim

# 配置
sudo mkdir -p /etc/certim
sudo cp configs/certim.example.yaml /etc/certim/config.yaml
# 编辑 /etc/certim/config.yaml 修改监听地址、目录等

# 安装并启动服务
sudo cp systemd/certim.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now certim

# 验证
certim status
```

### 业务节点（运行 ctnode）

```bash
# 从 GitHub Releases 下载二进制到 bin/（手动安装时使用）
sudo cp bin/ctnode-linux-amd64 /usr/local/bin/ctnode
sudo chmod 0755 /usr/local/bin/ctnode

# 配置
sudo mkdir -p /etc/ctnode /var/lib/ctnode /etc/certim/certificates
sudo cp configs/ctnode.example.yaml /etc/ctnode/config.yaml
# 编辑 /etc/ctnode/config.yaml 填写 Server URL 和身份密钥路径

# 注册并启动
sudo ctnode enroll --token ctm_enroll_xxx --config /etc/ctnode/config.yaml
sudo cp systemd/ctnode.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ctnode

# 验证
ctnode status --config /etc/ctnode/config.yaml
```

### 一键安装

#### 在线安装

```bash
# 直连官方 GitHub
curl -fsSL https://raw.githubusercontent.com/Aceak/Certim-Release/main/install.sh \
  | sudo bash -s -- certim

# 国内网络使用镜像站（脚本与二进制均走 https://ghfast.top）
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/Aceak/Certim-Release/main/install.sh \
  | sudo bash -s -- certim --mirror
```

`certim` 可替换为 `ctnode` 或 `all`。

#### 本地脚本安装

```bash
# 安装 certim
sudo ./install.sh certim

# 安装 ctnode
sudo ./install.sh ctnode

# 同时安装
sudo ./install.sh all
```

安装脚本自动从 GitHub Releases 下载对应架构的二进制，校验 SHA-256 后安装
到 `/usr/local/bin`，并复制配置示例和 systemd 单元。

下载默认直连官方 GitHub，可选参数：

```bash
# 指定发布版本（默认 latest）
sudo ./install.sh all --version v1.2.3

# 启用默认镜像 https://ghfast.top 加速
sudo ./install.sh certim --mirror

# 使用自定义镜像前缀
sudo ./install.sh certim --mirror https://mirror.example.com
```

如镜像不可用，更换 `--mirror` 的值重试即可。手动下载方式见上文"快速安装"。

### 卸载

```bash
# 卸载本机已安装的组件（自动检测 certim 或 ctnode）
sudo ./install.sh uninstall

# 同时清除数据与配置目录（/var/lib/*、/etc/certim、/etc/ctnode 等）
sudo ./install.sh uninstall --purge
```

不带 `--purge` 时保留数据与配置目录，便于重装后继续使用。

## 配置说明

### certim 服务端

YAML 仅保存引导设置（监听地址、目录、续期间隔）。ACME 账户、DNS 凭据、
Storage Profile 和证书通过本地 CLI 动态管理，存储在 SQLite 中。
敏感内容写入 `.credentials` 目录，不会进入 SQLite。

关键配置项：

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `server.listen` | `127.0.0.1:9080` | Agent API 监听地址，建议置于反向代理之后 |
| `server.control_socket` | `/run/certim/certim.sock` | 本地管理 CLI 的 Unix Socket |
| `server.data_dir` | `/var/lib/certim` | SQLite 和证书本地存储 |
| `server.credentials_dir` | `/etc/certim/.credentials` | Profile 凭据目录（0700） |
| `acme.renew_before` | `30d` | 证书到期前多少天触发续期 |
| `acme.check_interval` | `7d` | 续期状态检查间隔 |

### ctnode Agent

Agent 自动发现已获授权的证书，无需在配置中逐个填写域名。
不保存 DNS 或云存储凭据。

关键配置项：

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `server.url` | - | Certim Agent API 的 HTTPS 地址（必填） |
| `server.insecure_skip_verify` | `false` | 仅在自签名测试环境开启 |
| `identity.key` | `/var/lib/ctnode/identity.key` | Ed25519 身份密钥 |
| `poll.interval` | `7d` | 证书版本轮询间隔 |
| `poll.jitter` | `10%` | 轮询随机偏移，避免惊群 |
| `storage.root` | `/etc/certim/certificates` | 证书部署根目录 |
| `storage.outputs.split` | `false` | 额外生成 certificate.pem 和 chain.pem |
| `storage.outputs.pfx` | `false` | 额外生成 PFX/P12 和随机密码 |
| `deploy.check` | `["nginx", "-t"]` | 部署后配置检查命令 |
| `deploy.reload` | `["systemctl", "reload", "nginx"]` | 部署后重载命令 |

## systemd 服务管理

```bash
# certim
systemctl status certim
systemctl start certim
systemctl stop certim
journalctl -u certim -f

# ctnode
systemctl status ctnode
systemctl start ctnode
systemctl stop ctnode
journalctl -u ctnode -f
```

两个服务均配置为崩溃后自动重启（`Restart=on-failure`），并依赖 `network-online.target`。

## Agent API 反向代理

生产环境建议在 HTTPS 反向代理后暴露 Agent API，参考
[nginx/nginx-certim.example.conf](nginx/nginx-certim.example.conf)。
反向代理必须把 `X-Forwarded-For` 覆盖为单个客户端 IP——逗号分隔的转发链会被
拒绝并回退到 TCP 对端地址。OSS 预签名 URL 由 Agent 直接访问阿里云 OSS，
不经过代理。

## 目录权限

| 路径 | 权限 | 说明 |
|------|------|------|
| `/etc/certim/` | `0755` | certim 配置目录 |
| `/etc/certim/.credentials/` | `0700` | Profile 凭据目录 |
| `/var/lib/certim/` | `0755` | certim 数据目录（systemd StateDirectory 创建） |
| `/run/certim/` | `0750` | Unix Socket 目录（tmpfs） |
| `/etc/ctnode/` | `0755` | ctnode 配置目录 |
| `/var/lib/ctnode/` | `0755` | ctnode 身份密钥目录（systemd StateDirectory 创建） |
| `/etc/certim/certificates/` | `0755` | ctnode 证书部署目录 |

## 多架构二进制

| 二进制 | 平台 |
|--------|------|
| `certim-linux-amd64` | Linux x86_64 |
| `certim-linux-arm64` | Linux ARM64 |
| `ctnode-linux-amd64` | Linux x86_64 |
| `ctnode-linux-arm64` | Linux ARM64 |
| `ctnode-darwin-amd64` | macOS x86_64 |
| `ctnode-darwin-arm64` | macOS ARM64 |
| `ctnode-windows-amd64.exe` | Windows x86_64 |
| `ctnode-windows-arm64.exe` | Windows ARM64 |

`certim` 使用纯 Go 的 `modernc.org/sqlite` 驱动，与 `ctnode` 一样无需 CGO。
certim 服务端仅发布 Linux 平台，ctnode Agent 支持 Linux、macOS 和 Windows。

## 版本校验

每个发布版本附带 `checksums.txt`。将下载的二进制放入 `bin/`、校验文件放到仓库
根目录后执行：

```bash
cd bin && sha256sum -c ../checksums.txt
```

## 安全要求

- certim 服务端和 Agent API 之间的 TLS 必须启用。
- Agent API 应置于 HTTPS 反向代理之后，由防火墙限制来源 IP。
- `insecure_skip_verify` 仅用于受控测试环境。
- Enrollment Token 只在创建时显示一次，请妥善保存。
- 私钥和凭据文件的系统权限必须限制。

## 相关资源

- [Certim 主仓库](https://github.com/Aceak/Certim) — 完整文档、设计说明和源码。
- [Let's Encrypt](https://letsencrypt.org/) — 免费 TLS 证书 CA。
- [RFC 8555](https://datatracker.ietf.org/doc/html/rfc8555) — ACME 协议规范。
