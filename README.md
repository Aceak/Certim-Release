# Certim Release

Certim 生产部署资源仓库。预编译二进制通过 GitHub Releases 发布，本仓库提供
systemd 单元、配置示例、Nginx 反代示例和安装脚本，让生产节点快速搭建
Certim 服务端和 ctnode Agent。

## 仓库内容

```text
Release/
├── README.md                        # 本文件
├── install.sh                       # 一键安装/卸载/升级脚本
├── compatibility.conf               # 升级兼容性规则
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
# 模板不含 Server URL:注册时由 enroll --url 写入,无需手动编辑

# 注册并启动
sudo ctnode enroll --url https://certim.example.com --token ctm_xxx --config /etc/ctnode/config.yaml
sudo cp systemd/ctnode.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ctnode

# 验证
ctnode status --config /etc/ctnode/config.yaml
```

### 让服务读到证书

Agent 把证书部署到 `/etc/certim/certificates/<证书名>/`。服务若要求从自己的路径
读取（如 nginx 的 `/etc/nginx/ssl/<证书名>/`），配置符号链接目录即可：

```yaml
storage:
  link_dirs: ["/etc/nginx/ssl"]
```

链接指向目录而非文件，只在首次部署时建立，续期的原子替换不会影响它。已存在但
指向别处的链接会被拒绝而不是覆盖。

使用本仓库的 `systemd/ctnode.service` 时，`ProtectSystem=strict` 下需把每个
`link_dirs` 目标目录加进该单元的 `ReadWritePaths`，否则建链会因 EROFS 失败
（证书照常部署，链接缺失并在日志中 warning）。

查看本机证书与版本：

```bash
sudo ctnode certs              # 本机已部署的证书
sudo ctnode certs --remote     # 叠加服务端授权的版本，两侧差异一眼可见
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

`certim` 可替换为 `ctnode`。

#### 本地脚本安装

```bash
# 安装 certim
sudo ./install.sh certim

# 安装 ctnode
sudo ./install.sh ctnode
```

安装脚本自动从 GitHub Releases 下载对应架构的二进制（始终为最新版本），
校验 SHA-256 后安装到 `/usr/local/bin`，并复制配置示例和 systemd 单元。
在线安装（curl | bash）时配置文件与 systemd 单元会从仓库自动下载。

下载默认直连官方 GitHub，可选参数：

```bash
# 启用默认镜像 https://ghfast.top 加速
sudo ./install.sh certim --mirror

# 使用自定义镜像前缀
sudo ./install.sh certim --mirror https://mirror.example.com
```

如镜像不可用，更换 `--mirror` 的值重试即可。手动下载方式见上文"快速安装"。

### 卸载

```bash
# 卸载本机已安装的组件（自动检测 certim 或 ctnode），保留数据与配置目录
sudo ./install.sh uninstall

# 同时清除数据与配置目录（/var/lib/*、/etc/certim、/etc/ctnode 等）
# 并清理早期版本创建的系统用户
sudo ./install.sh purge
```

### 升级

```bash
# 升级本机已安装的全部组件（自动检测 certim / ctnode）
sudo ./install.sh upgrade

# 只升级 certim
sudo ./install.sh upgrade certim

# 在线升级（国内网络使用镜像）
curl -fsSL https://raw.githubusercontent.com/Aceak/Certim-Release/main/install.sh \
  | sudo bash -s -- upgrade --mirror
```

升级到最新发布版本，流程为：

1. 先做兼容性检查（见下文「兼容性规则」），不满足的规则会在写入任何文件之前阻断；
2. 备份当前二进制到 `/usr/local/bin/<name>.old`；
3. 替换二进制并刷新 systemd 单元；
4. 服务处于运行状态时自动重启以加载新二进制，否则保持停止。

配置与数据目录保持不变；SQLite 结构迁移由新版二进制首次启动时自动完成，
无需人工干预。已是最新版本时直接跳过。升级失败时可手动回滚：

```bash
sudo cp /usr/local/bin/certim.old /usr/local/bin/certim
sudo systemctl restart certim
```

### 兼容性规则

升级兼容性约束独立维护在 [compatibility.conf](compatibility.conf) 中，无需修改
脚本即可追加规则。`upgrade` 在执行任何写入之前读取该文件：本地执行时直接读取，
在线执行（curl | bash）时从 main 分支下载；下载失败时告警并跳过兼容性检查。

三种规则：

| 规则 | 作用 | 不满足时 |
|------|------|----------|
| `requires` | 升级某组件到某版本区间要求本机另一组件满足版本约束 | 阻断；依赖组件未安装时仅提示 |
| `step` | 低于某版本的组件不能直接升级到目标版本，须分两步 | 阻断 |
| `matrix` | 同机两个组件版本落入声明的不兼容区间 | 告警，不阻断 |

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
| `server.data_dir` | `/var/lib/certim` | SQLite、证书版本历史与审计日志 |
| `server.certificates_dir` | `/etc/certim/.certificates` | 证书固定落盘目录，续期直接覆盖 |
| `server.credentials_dir` | `/etc/certim/.credentials` | Profile 凭据目录（0700） |
| `server.trusted_proxies` | 回环网段 | 信任 `X-Forwarded-For` 的反向代理地址，见「Agent API 反向代理」 |
| `server.access_log` | `/var/log/certim/access.log` | HTTP 访问日志，与运行日志（journal）分开 |
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
| `storage.link_dirs` | 空 | 在这些目录下为每张证书建立同名符号链接，指向部署目录 |
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

代理必须把**直连客户端地址追加**到 `X-Forwarded-For` 链尾（nginx 用
`$proxy_add_x_forwarded_for`），而不是覆盖成 `$remote_addr`。服务端仅在 TCP
直连对端属于 `server.trusted_proxies`（默认回环网段）时才信任该头，并从最近
一跳起取链上第一个非可信地址作为真实客户端；其余来源一律使用 TCP 对端地址。
nginx 不在本机时需把**代理机器的地址**加入 `trusted_proxies`（如 `10.0.0.5/32`）。
**切勿**把包含客户端或 Agent 的网段（如整个 LAN）列入，否则伪造的头值会生效；
配置为显式空列表 `[]` 则永不信任该头。

OSS 预签名 URL 由 Agent 直接访问阿里云 OSS，不经过代理。

## 目录权限

| 路径 | 权限 | 说明 |
|------|------|------|
| `/etc/certim/` | `0755` | certim 配置目录 |
| `/etc/certim/.credentials/` | `0700` | Profile 凭据目录 |
| `/var/lib/certim/` | `0755` | certim 数据目录（systemd StateDirectory 创建） |
| `/var/log/certim/` | `0750` | HTTP 访问日志目录（systemd LogsDirectory 创建） |
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
- `insecure_skip_verify` 仅用于受控测试环境。`ctnode` 的 `enroll`、`sync`、
  `status`、`check` 也接受 `-k`/`--insecure`，可对单次命令跳过服务端证书验证，
  不写入配置。
- Enrollment Token 只在创建时显示一次，请妥善保存。
- 私钥和凭据文件的系统权限必须限制。

## 相关资源

- [Certim 主仓库](https://github.com/Aceak/Certim) — 完整文档、设计说明和源码。
- [Let's Encrypt](https://letsencrypt.org/) — 免费 TLS 证书 CA。
- [RFC 8555](https://datatracker.ietf.org/doc/html/rfc8555) — ACME 协议规范。
