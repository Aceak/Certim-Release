# Certim Release

Certim 生产部署资源仓库。提供预编译二进制、systemd 单元、配置示例和安装脚本，
让生产节点快速搭建 Certim 服务端和 ctnode Agent。

## 仓库内容

```text
Release/
├── README.md                        # 本文件
├── install.sh                       # 一键安装脚本
├── configs/
│   ├── certim.example.yaml          # certim 服务端配置示例
│   └── ctnode.example.yaml          # ctnode Agent 配置示例
├── systemd/
│   ├── certim.service               # certim 服务端 systemd 单元
│   └── ctnode.service               # ctnode Agent systemd 单元
└── bin/                             # 发布二进制（由 CI 产出）
```

## 快速安装

### 证书管理节点（运行 certim serve）

```bash
# 下载二进制
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
# 下载二进制
sudo cp bin/ctnode-linux-amd64 /usr/local/bin/ctnode
sudo chmod 0755 /usr/local/bin/ctnode

# 配置
sudo mkdir -p /etc/ctnode /var/lib/ctnode
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

```bash
# 安装 certim
sudo ./install.sh certim

# 安装 ctnode
sudo ./install.sh ctnode

# 同时安装
sudo ./install.sh all
```

安装脚本使用当前系统架构自动选择对应二进制。

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

## 目录权限

| 路径 | 权限 | 说明 |
|------|------|------|
| `/etc/certim/` | `0755` | certim 配置目录 |
| `/etc/certim/.credentials/` | `0700` | Profile 凭据目录 |
| `/var/lib/certim/` | `0750` | certim 数据目录 |
| `/run/certim/` | `0755` | Unix Socket 目录（tmpfs） |
| `/etc/ctnode/` | `0755` | ctnode 配置目录 |
| `/var/lib/ctnode/` | `0750` | ctnode 身份密钥目录 |
| `/etc/certim/certificates/` | `0755` | ctnode 证书部署目录 |

## 多架构二进制

| 二进制 | 平台 |
|--------|------|
| `certim-linux-amd64` | Linux x86_64（CGO 依赖） |
| `certim-linux-arm64` | Linux ARM64（CGO 依赖） |
| `ctnode-linux-amd64` | Linux x86_64（纯 Go） |
| `ctnode-linux-arm64` | Linux ARM64（纯 Go） |
| `ctnode-darwin-amd64` | macOS x86_64（纯 Go） |
| `ctnode-darwin-arm64` | macOS ARM64（纯 Go） |
| `ctnode-windows-amd64.exe` | Windows x86_64（纯 Go） |
| `ctnode-windows-arm64.exe` | Windows ARM64（纯 Go） |

certim 服务端仅发布 Linux 平台（依赖 CGO + SQLite）。ctnode Agent 为纯 Go，
支持 Linux、macOS 和 Windows。

## 版本校验

每个发布版本附带 `checksums.txt`：

```bash
sha256sum -c dist/checksums.txt
```

## 安全要求

- certim 服务端和 Agent API 之间的 TLS 必须启用。
- Agent API 应置于 HTTPS 反向代理之后，由防火墙限制来源 IP。
- `insecure_skip_verify` 仅用于受控测试环境。
- Enrollment Token 只在创建时显示一次，请妥善保存。
- 私钥和凭据文件的系统权限必须限制。

## 相关资源

- [Certim 主仓库](https://github.com/3kk0/certim) — 完整文档、设计说明和源码。
- [Let's Encrypt](https://letsencrypt.org/) — 免费 TLS 证书 CA。
- [RFC 8555](https://datatracker.ietf.org/doc/html/rfc8555) — ACME 协议规范。
