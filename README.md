# vps-init

Oracle Cloud Ubuntu 服务器一键初始化脚本。重装系统后快速完成环境配置。

## 功能特性

- **系统更新**：`apt update && apt upgrade`
- **基础工具**：curl、wget、git、vim、net-tools、tmux、dnsutils、apt-transport-https、neofetch、btop（另装依赖：gnupg、ca-certificates）
- **Caddy**：官方 apt 源安装，开机自启
- **Docker**：Docker CE + Compose 插件（官方源），自动将当前用户加入 `docker` 组
- **BBR**：启用 Google BBR 拥塞控制加速（自动加载 `tcp_bbr` 模块并在开机时提前加载，内核不支持时自动跳过）
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
| INPUT | DROP（仅放行 SSH 22、Web 80/443、回环、已建立连接、Docker 网桥 `docker0`/`br-+`） |
| FORWARD | ACCEPT |
| OUTPUT | ACCEPT |

> INPUT 放行 `docker0`/`br-+` 网桥流量是**必需的**：Docker 不会自动添加此类规则，若不放行，`INPUT DROP` 会阻断容器访问宿主机端口（moby#27817）。代价是容器可访问宿主机的任意端口，这是 Docker 网络的默认行为。若需收紧，可自行在 DOCKER-USER 链中限制。

可通过脚本顶部变量调整：

```bash
SSH_PORT=22          # SSH 端口
WEB_PORTS="80 443"   # 开放的 Web 端口
ALLOW_PING=1         # 1=允许 ping，0=拒绝
ENABLE_BBR=1         # 1=启用 BBR，0=禁用
```

## 注意事项

- Oracle 云控制台的**安全列表（Security List/NSG）**也需放行 80/443，脚本只负责服务器内部的防火墙
- Docker 运行期间不要手动执行 `iptables-save`，否则会把 Docker 生成的链写入持久化规则导致重启后恢复失败
- 脚本幂等，可重复执行
