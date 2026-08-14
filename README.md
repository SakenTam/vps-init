# vps-init

Oracle Cloud Ubuntu 服务器一键初始化脚本。重装系统后快速完成环境配置。

## 功能特性

- **系统更新**：`apt update && apt upgrade`
- **基础工具**：curl、wget、git、vim、net-tools、tmux、dnsutils、apt-transport-https、neofetch、btop（另装依赖：gnupg、ca-certificates）
- **Caddy**：官方 apt 源安装，开机自启
- **Docker**：Docker CE + Compose 插件（官方源），自动将当前用户加入 `docker` 组
- **BBR**：启用 Google BBR 拥塞控制加速（自动加载 `tcp_bbr` 模块并在开机时提前加载，内核不支持时自动跳过）
- **SSH 加固**：强制密钥登录（禁用密码登录、禁止 root 密码登录、最多尝试 3 次），未检测到 `authorized_keys` 时自动跳过防锁死
- **journald 持久化**：系统日志跨重启保留（上限 512M 自动轮换），作为监控与审计的数据源
- **fail2ban**：sshd 防暴力破解，基于 systemd 后端直接读 journal，指数递增封禁（首次 10 分钟，每次翻倍，上限 7 天）
- **SSH 登录监控**：`ssh-monitor.sh` 统计登录用户/来源 IP/时间，实时 watch，cron 每分钟增量写入审计日志 `/var/log/ssh-logins.log`
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
SSH_PORT=22                    # SSH 端口
WEB_PORTS="80 443"             # 开放的 Web 端口
ALLOW_PING=1                   # 1=允许 ping，0=拒绝
ENABLE_BBR=1                   # 1=启用 BBR，0=禁用
HARDEN_SSH=1                   # 1=禁用密码登录，0=跳过加固
FAIL2BAN_BANTIME=600           # 首次封禁时长（秒）
FAIL2BAN_BANTIME_FACTOR=2      # 每次重犯封禁时长翻倍
FAIL2BAN_BANTIME_MAX=604800    # 封禁时长上限（秒）= 7 天
FAIL2BAN_FINDTIME=600          # 统计时间窗（秒）= 10 分钟
FAIL2BAN_MAXRETRY=3            # 时间窗内失败次数触发封禁
```

## SSH 登录监控

安装后可通过 `ssh-monitor.sh` 查看登录统计：

```bash
ssh-monitor.sh                      # 近 7 天统计摘要 + 最近登录
ssh-monitor.sh --users              # 按登录用户统计
ssh-monitor.sh --ips                # 按来源 IP 统计
ssh-monitor.sh --today              # 今日登录明细
ssh-monitor.sh --since "1 month ago"  # 自定义时间窗口
ssh-monitor.sh --failed             # 最近失败尝试 + fail2ban 封禁列表
ssh-monitor.sh --watch              # 实时监控登录（Ctrl+C 退出）
```

数据全部来自 journald（已持久化），不受 auth.log 轮转影响。同时 cron 每分钟将**新增**的成功登录增量追加到 `/var/log/ssh-logins.log`（基于 journald 游标增量读取，游标失效会自动重置自愈，并用 `flock` 防止并发重复写入），便于快速 grep 审计。

> 时间显示与审计日志均为 **UTC**（journald 内部使用 UTC 存储），换算本地时区可 `TZ='Asia/Shanghai' date -d '2026-08-15 14:02:31 UTC'`。

## 查看 SSH 登录日志

```bash
# 1. 审计日志（cron 每分钟增量追加，适合快速 grep）
cat /var/log/ssh-logins.log                    # 全部成功登录记录
grep '^2026-08-15' /var/log/ssh-logins.log     # 按日期过滤
tail -f /var/log/ssh-logins.log                # 实时跟踪新登录

# 2. journald 原始日志（含失败记录，持久化保存）
journalctl _COMM=sshd --since today            # 今日全部 sshd 日志
journalctl _COMM=sshd | grep 'Failed password' # 失败登录（暴力破解）
journalctl _COMM=sshd | grep 'Accepted'        # 成功登录

# 3. 统计报表 / 实时监控
ssh-monitor.sh                                 # 近 7 天统计摘要 + 最近登录
ssh-monitor.sh --users                         # 按用户统计
ssh-monitor.sh --ips                           # 按来源 IP 统计
ssh-monitor.sh --today                         # 今日登录明细
ssh-monitor.sh --since "1 month ago"           # 自定义时间窗口
ssh-monitor.sh --failed                        # 最近失败尝试 + fail2ban 封禁列表
ssh-monitor.sh --watch                         # 实时监控登录（Ctrl+C 退出）

# 4. 暴力破解拦截情况
fail2ban-client status sshd                    # 封禁中的 IP
fail2ban-client unban <IP>                     # 手动解封
```

## fail2ban 说明

- 采用**指数递增封禁**：首次封禁 10 分钟，同一 IP 反复触发则每次翻倍，最长封禁 7 天
- 当前 SSH 连接 IP、回环地址、内网网段（10/8、172.16/12、192.168/16）已自动加入白名单，防止误封；若通过云控制台执行（无 `SSH_CONNECTION`），脚本会警告未加入白名单
- 使用 **systemd 后端**直接从 journal 读取失败记录，并显式覆盖 `journalmatch = _SYSTEMD_UNIT=ssh.service`——因为 Ubuntu 的 sshd 服务单元名是 `ssh.service` 而非 fail2ban 默认的 `sshd.service`（不覆盖将导致任何失败都检测不到）
- **[sshd] 使用 `mode = aggressive`**：默认 `normal` 模式会把 `Failed publickey` 和 `Connection closed by authenticating user ... [preauth]` 标记为「不计为失败」(`NOFAIL`)。但脚本已禁用密码登录，攻击者只能产生这两类日志（无法产生 `Failed password`），若不启用 aggressive 模式 fail2ban 将**形同虚设**。aggressive 会额外计数：端口扫描器（`Did not receive identification string`）、preauth 阶段断开/重置的连接等真实攻击信号
- 封禁机制随版本自动选择：Ubuntu 20.04/22.04 使用 iptables 链（`f2b-sshd`），24.04 使用 nftables 表（`inet f2b-table`），均挂接在 INPUT 链之前，与脚本的 iptables 防火墙规则正确叠加。脚本在重建防火墙前会**先停掉 fail2ban 与 Docker**，保存干净规则后再由后续步骤重启，因此不要在 fail2ban/Docker 运行期间手动执行 `iptables-save`
- 运行 `fail2ban-client status sshd` 查看封禁状态；`fail2ban-client unban <IP>` 手动解封

## 注意事项

- Oracle 云控制台的**安全列表（Security List/NSG）**也需放行 80/443，脚本只负责服务器内部的防火墙
- 脚本幂等，可重复执行；重跑时 Docker/fail2ban 会短暂停止后由脚本自动拉起（已部署的容器不受影响，仅中断约几分钟）
- SSH 加固后仅允许密钥登录，若通过 `sudo bash init-server.sh` 执行，脚本会自动识别当前登录用户并检查其 `authorized_keys`，不存在时会跳过加固以防锁死
