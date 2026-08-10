# vps-init

Oracle Cloud Ubuntu 服务器一键初始化脚本。重装系统后快速完成环境配置。

## 功能特性

- **系统更新**：`apt update && apt upgrade`
- **基础工具**：curl、wget、git、vim、net-tools、tmux、dnsutils、apt-transport-https、neofetch、btop（另装依赖：gnupg、ca-certificates）
- **Caddy**：官方 apt 源安装，开机自启
- **Docker**：Docker CE + Compose 插件（官方源），自动将当前用户加入 `docker` 组
- **防火墙**：iptables 仅开放 22/80/443 端口，FORWARD 保持放行（不影响 Docker 容器网络），通过 `netfilter-persistent` 持久化

## 使用前提

- Ubuntu 20.04 / 22.04 / 24.04
- 以 `ubuntu` 用户登录，具备 sudo 权限

## 使用方法

### 一键脚本（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/SakenTam/vps-init/main/init-server.sh | sudo bash
```

### 手动方式

```bash
curl -O https://raw.githubusercontent.com/SakenTam/vps-init/main/init-server.sh
chmod +x init-server.sh
sudo ./init-server.sh
```

运行完成后**重新登录**一次，使 docker 组权限生效。

## 防火墙说明

默认策略：

| 链 | 策略 |
|---|---|
| INPUT | DROP（仅放行 SSH 22、Web 80/443、回环、已建立连接） |
| FORWARD | ACCEPT |
| OUTPUT | ACCEPT |

可通过脚本顶部变量调整：

```bash
SSH_PORT=22          # SSH 端口
WEB_PORTS="80 443"   # 开放的 Web 端口
ALLOW_PING=1         # 1=允许 ping，0=拒绝
```

## 注意事项

- Oracle 云控制台的**安全列表（Security List/NSG）**也需放行 80/443，脚本只负责服务器内部的防火墙
- Docker 运行期间不要手动执行 `iptables-save`，否则会把 Docker 生成的链写入持久化规则导致重启后恢复失败
- 脚本幂等，可重复执行
