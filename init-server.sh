#!/usr/bin/env bash
set -euo pipefail

SSH_PORT=22
WEB_PORTS="80 443"
ALLOW_PING=1
ENABLE_BBR=1
INIT_USER="${SUDO_USER:-ubuntu}"
HARDEN_SSH=1
FAIL2BAN_BANTIME=600
FAIL2BAN_BANTIME_FACTOR=2
FAIL2BAN_BANTIME_MAX=604800
FAIL2BAN_FINDTIME=600
FAIL2BAN_MAXRETRY=3

C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_CYAN='\033[0;36m'
C_RESET='\033[0m'

info() { printf "${C_CYAN}[信息]${C_RESET} %s\n" "$*"; }
ok()   { printf "${C_GREEN}[完成]${C_RESET} %s\n" "$*"; }
warn() { printf "${C_YELLOW}[注意]${C_RESET} %s\n" "$*"; }
die()  { printf "${C_RED}[错误]${C_RESET} %s\n" "$*" >&2; exit 1; }

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "请使用 sudo 运行：sudo bash $0"
  fi
}

check_os() {
  . /etc/os-release
  [ "$ID" = "ubuntu" ] || die "仅支持 Ubuntu 系统，当前为 $ID"
  case "$VERSION_ID" in
    20.04|22.04|24.04) ok "系统 Ubuntu $VERSION_ID，版本符合要求" ;;
    *) die "不支持的 Ubuntu 版本 $VERSION_ID（仅支持 20.04/22.04/24.04）" ;;
  esac
}

update_system() {
  info "更新系统软件包..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get -y -o Dpkg::Options::="--force-confold" upgrade
  ok "系统更新完成"
}

install_base_tools() {
  export DEBIAN_FRONTEND=noninteractive
  info "安装仓库依赖（gpg、CA 证书）..."
  apt-get install -y gnupg ca-certificates
  info "安装基础工具..."
  apt-get install -y curl wget git vim net-tools tmux dnsutils apt-transport-https neofetch btop
  ok "基础工具安装完成"
}

setup_caddy() {
  export DEBIAN_FRONTEND=noninteractive
  info "安装 Caddy..."
  if apt-cache show caddy > /dev/null 2>&1; then
    apt-get install -y caddy
  else
    info "系统源中未找到 caddy，改用官方仓库安装..."
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
    apt-get update
    apt-get install -y caddy
  fi
  systemctl enable --now caddy
  ok "Caddy 安装并已启用"
}

setup_docker() {
  info "安装 Docker CE + Compose 插件..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $CODENAME stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  if id "$INIT_USER" > /dev/null 2>&1; then
    usermod -aG docker "$INIT_USER"
    warn "已将用户 $INIT_USER 加入 docker 组，需重新登录后 docker 命令才无需 sudo"
  else
    warn "用户 $INIT_USER 不存在，跳过加入 docker 组"
  fi
  ok "Docker 安装完成"
}

setup_bbr() {
  if [ "$ENABLE_BBR" != "1" ]; then
    return
  fi
  info "启用 BBR 加速..."
  modprobe tcp_bbr 2>/dev/null || true
  if ! grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    warn "当前内核不支持 BBR，跳过"
    return
  fi
  echo "tcp_bbr" > /etc/modules-load.d/tcp-bbr.conf
  cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  if ! sysctl --system > /dev/null 2>&1; then
    warn "sysctl 部分配置应用失败，已按实际结果核验"
  fi
  if [ "$(cat /proc/sys/net/ipv4/tcp_congestion_control)" = "bbr" ]; then
    ok "BBR 已启用（当前算法：$(sysctl -n net.ipv4.tcp_congestion_control)）"
  else
    warn "BBR 配置未生效，当前算法：$(sysctl -n net.ipv4.tcp_congestion_control)"
  fi
}

setup_firewall() {
  info "配置 iptables 防火墙（INPUT 仅开放 ${SSH_PORT}/$(echo "$WEB_PORTS" | tr ' ' '/')）..."
  export DEBIAN_FRONTEND=noninteractive
  echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
  echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
  apt-get install -y iptables-persistent > /dev/null
  systemctl enable netfilter-persistent > /dev/null 2>&1 || true

  systemctl stop docker > /dev/null 2>&1 || true
  systemctl stop fail2ban > /dev/null 2>&1 || true

  if command -v ufw > /dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    warn "检测到 UFW 已启用，为避免与 iptables 规则冲突将禁用 UFW"
    ufw disable > /dev/null
  fi

  iptables -P INPUT ACCEPT
  iptables -F
  iptables -X || true

  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
  for p in $WEB_PORTS; do
    iptables -A INPUT -p tcp --dport "$p" -j ACCEPT
  done
  iptables -A INPUT -i docker0 -j ACCEPT
  iptables -A INPUT -i br-+ -j ACCEPT
  if [ "$ALLOW_PING" = "1" ]; then
    iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
  fi

  iptables -P INPUT DROP
  iptables -P FORWARD ACCEPT
  iptables -P OUTPUT ACCEPT

  iptables-save > /etc/iptables/rules.v4
  ok "IPv4 规则已保存到 /etc/iptables/rules.v4"

  if [ -f /proc/net/if_inet6 ] && command -v ip6tables > /dev/null 2>&1; then
    ip6tables -P INPUT ACCEPT
    ip6tables -F
    ip6tables -X || true
    ip6tables -A INPUT -i lo -j ACCEPT
    ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
    for p in $WEB_PORTS; do
      ip6tables -A INPUT -p tcp --dport "$p" -j ACCEPT
    done
    ip6tables -A INPUT -i docker0 -j ACCEPT
    ip6tables -A INPUT -i br-+ -j ACCEPT
    ip6tables -A INPUT -p ipv6-icmp -m icmp6 --icmpv6-type 133 -j ACCEPT
    ip6tables -A INPUT -p ipv6-icmp -m icmp6 --icmpv6-type 134 -j ACCEPT
    ip6tables -A INPUT -p ipv6-icmp -m icmp6 --icmpv6-type 135 -j ACCEPT
    ip6tables -A INPUT -p ipv6-icmp -m icmp6 --icmpv6-type 136 -j ACCEPT
    if [ "$ALLOW_PING" = "1" ]; then
      ip6tables -A INPUT -p ipv6-icmp -m icmp6 --icmpv6-type echo-request -j ACCEPT
    fi
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD ACCEPT
    ip6tables -P OUTPUT ACCEPT
    ip6tables-save > /etc/iptables/rules.v6
    ok "IPv6 规则已保存到 /etc/iptables/rules.v6"
  else
    warn "系统未启用 IPv6，跳过 ip6tables 配置"
  fi
}

setup_ssh_hardening() {
  if [ "$HARDEN_SSH" != "1" ]; then
    warn "已跳过 SSH 加固（HARDEN_SSH=0）"
    return
  fi
  info "加固 SSH：仅允许密钥登录..."

  LOGIN_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
  KEY_OK=0
  if [ "$LOGIN_USER" = "root" ]; then
    [ -s /root/.ssh/authorized_keys ] && KEY_OK=1
  elif [ -n "$LOGIN_USER" ]; then
    [ -s "/home/$LOGIN_USER/.ssh/authorized_keys" ] && KEY_OK=1
  fi
  if [ "$KEY_OK" -ne 1 ]; then
    warn "未检测到用户 $LOGIN_USER 的 authorized_keys，为防锁死已跳过禁用密码登录，请先配置密钥后重新执行"
    return
  fi

  mkdir -p /etc/ssh/sshd_config.d
  if [ "$LOGIN_USER" = "root" ]; then
    ROOT_LINE="PermitRootLogin prohibit-password"
  else
    ROOT_LINE="PermitRootLogin no"
  fi
  cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
PubkeyAuthentication yes
PasswordAuthentication no
$ROOT_LINE
MaxAuthTries 3
EOF
  chmod 644 /etc/ssh/sshd_config.d/99-hardening.conf

  if sshd -t; then
    systemctl restart ssh
    ok "SSH 已加固：禁止密码登录 / 禁止 root 密码登录 / 最多尝试 3 次（$ROOT_LINE）"
  else
    warn "sshd 配置校验失败，已回滚，请检查 /etc/ssh/sshd_config.d/99-hardening.conf"
    rm -f /etc/ssh/sshd_config.d/99-hardening.conf
  fi
}

setup_journald_persist() {
  info "启用 journald 持久化日志..."
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/00-persistent.conf <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=512M
EOF
  systemctl restart systemd-journald 2>/dev/null || true
  if [ -d /var/log/journal ]; then
    ok "journald 已持久化到 /var/log/journal（上限 512M，自动轮换）"
  else
    warn "journald 持久化目录未生成，请检查 journalctl -b 输出"
  fi
}

setup_fail2ban() {
  export DEBIAN_FRONTEND=noninteractive
  info "安装 fail2ban..."
  apt-get install -y fail2ban > /dev/null

  CURRENT_IP="$(echo "${SSH_CONNECTION:-}" | awk '{print $1}')"
  cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
backend = systemd
bantime = $FAIL2BAN_BANTIME
bantime.increment = true
bantime.factor = $FAIL2BAN_BANTIME_FACTOR
bantime.maxtime = $FAIL2BAN_BANTIME_MAX
findtime = $FAIL2BAN_FINDTIME
maxretry = $FAIL2BAN_MAXRETRY
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 ${CURRENT_IP:-}

[sshd]
enabled = true
port = $SSH_PORT
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd
EOF

  systemctl enable fail2ban
  systemctl restart fail2ban
  STATUS_OK=0
  for _ in 1 2 3 4 5; do
    if fail2ban-client status sshd > /dev/null 2>&1; then
      STATUS_OK=1
      break
    fi
    sleep 1
  done
  if [ "$STATUS_OK" = "1" ]; then
    ok "fail2ban 已启用（sshd：失败 ${FAIL2BAN_MAXRETRY} 次/${FAIL2BAN_FINDTIME}s 封禁，首次 ${FAIL2BAN_BANTIME}s，每次翻倍至 ${FAIL2BAN_BANTIME_MAX}s）"
  else
    warn "fail2ban 启动异常，请检查：fail2ban-client status / journalctl -u fail2ban -n 50"
  fi
  if [ -z "$CURRENT_IP" ]; then
    warn "未检测到当前 SSH 连接 IP（可能通过云控制台执行），本次未将其加入白名单，请注意别把自己封了"
  fi
}

setup_ssh_monitor() {
  info "安装 SSH 登录监控（ssh-monitor）..."
  install -d -m 0755 /usr/local/bin
  cat > /usr/local/bin/ssh-monitor.sh <<'MONITOR_EOF'
#!/usr/bin/env bash
# ssh-monitor.sh - SSH 登录监控与统计（基于 journald）
set -uo pipefail

AUDIT_LOG=/var/log/ssh-logins.log
STATE_DIR=/var/lib/ssh-monitor
CURSOR_FILE="$STATE_DIR/cursor"
JCTL="journalctl _COMM=sshd --no-pager --output=short-iso"

parse() {
  awk '{ t=$1; sub(/\+[0-9:]+/,"",t); u=""; ip="";
        for(i=1;i<=NF;i++){ if($i=="for") u=$(i+1); if($i=="from") ip=$(i+1) }
        printf "%s %s %s\n", t, u, ip }'
}

pretty() { sed 's/T/ /'; }

accepted() { $JCTL --since "$1" 2>/dev/null | grep 'Accepted ' || true; }
failed()   { $JCTL --since "$1" 2>/dev/null | grep 'Failed ' || true; }

usage() {
  echo "ssh-monitor.sh - SSH 登录监控与统计"
  echo "用法:"
  echo "  ssh-monitor.sh                    近 7 天登录统计摘要 + 最近登录"
  echo "  ssh-monitor.sh --users [窗口]     按用户统计成功登录（默认 7 days ago）"
  echo "  ssh-monitor.sh --ips [窗口]       按来源 IP 统计成功登录"
  echo "  ssh-monitor.sh --today            今日登录明细"
  echo "  ssh-monitor.sh --since \"7 days ago\"  自定义时间窗口的统计摘要"
  echo "  ssh-monitor.sh --failed [N]       最近 N 条失败尝试（默认 20）+ fail2ban 封禁列表"
  echo "  ssh-monitor.sh --watch            实时监控登录（Ctrl+C 退出）"
  echo "  ssh-monitor.sh --record           (内部) cron 增量写入审计日志"
  echo "  ssh-monitor.sh --help             帮助"
}

cmd_default() {
  local since="${1:-7 days ago}"
  local raw parsed total u_count ip_count
  raw="$(accepted "$since")"
  parsed="$(printf '%s\n' "$raw" | parse | grep -v '^ *$')"
  total="$(printf '%s\n' "$raw" | grep -c . || true)"
  u_count="$(printf '%s\n' "$parsed" | awk 'NF{c[$2]++} END{print length(c)}')"
  ip_count="$(printf '%s\n' "$parsed" | awk 'NF{c[$3]++} END{print length(c)}')"
  echo "===== SSH 登录统计（$since 起）====="
  echo "成功登录总数: ${total:-0}  |  登录用户数: ${u_count:-0}  |  来源 IP 数: ${ip_count:-0}"
  echo
  echo "最近成功登录（时间 用户 来源IP）:"
  printf '%s\n' "$parsed" | pretty | tail -n 10
}

cmd_users() {
  local since="${1:-7 days ago}"
  echo "===== 按用户统计成功登录（$since 起）====="
  echo "次数  用户   来源 IP"
  printf '%s\n' "$(accepted "$since")" | parse | awk '
    NF{ c[$2]++; key=$2" "$3; if(!(key in seen)){ seen[key]=1; ips[$2]=ips[$2]" "$3 } }
    END{ for(u in c) printf "%d   %s%s\n", c[u], u, ips[u] }' | sort -rn
}

cmd_ips() {
  local since="${1:-7 days ago}"
  echo "===== 按来源 IP 统计成功登录（$since 起）====="
  echo "次数  来源 IP"
  printf '%s\n' "$(accepted "$since")" | parse | awk '
    NF{ c[$3]++ }
    END{ for(ip in c) printf "%d   %s\n", c[ip], ip }' | sort -rn
}

cmd_failed() {
  local n="${1:-20}"
  echo "===== 最近 $n 条失败登录尝试（近 7 天）====="
  failed "7 days ago" | tail -n "$n" | awk '{ t=$1; sub(/\+.*/,"",t); sub(/T/," ",t); $1=t; print }'
  echo
  echo "===== fail2ban 当前封禁（sshd jail）====="
  fail2ban-client status sshd 2>/dev/null | sed -n '/Banned IP list/,+1p' | tail -n +2 || echo "无"
}

cmd_watch() {
  echo "实时监控 SSH 登录（Ctrl+C 退出）..."
  if command -v journalctl > /dev/null 2>&1; then
    exec journalctl -f _COMM=sshd --output=short
  else
    exec tail -f /var/log/auth.log
  fi
}

cmd_record() {
  mkdir -p "$STATE_DIR"
  touch "$AUDIT_LOG"
  local cursor="" tmp new_cursor
  [ -f "$CURSOR_FILE" ] && cursor="$(cat "$CURSOR_FILE" 2>/dev/null || true)"
  tmp="$(mktemp)"
  if [ -n "$cursor" ]; then
    $JCTL --after-cursor="$cursor" --show-cursor > "$tmp" 2>/dev/null || true
  else
    $JCTL -n 1 --show-cursor > "$tmp" 2>/dev/null || true
  fi
  new_cursor="$(grep -- '-- cursor:' "$tmp" | awk '{print $3}' || true)"
  if [ -n "$new_cursor" ]; then
    grep 'Accepted ' "$tmp" | parse | pretty >> "$AUDIT_LOG"
    printf '%s\n' "$new_cursor" > "$CURSOR_FILE"
  elif [ -n "$cursor" ]; then
    rm -f "$CURSOR_FILE"
    $JCTL -n 1 --show-cursor > "$tmp" 2>/dev/null || true
    new_cursor="$(grep -- '-- cursor:' "$tmp" | awk '{print $3}' || true)"
    [ -n "$new_cursor" ] && printf '%s\n' "$new_cursor" > "$CURSOR_FILE"
  fi
  rm -f "$tmp"
}

case "${1:-}" in
  --users)   cmd_users "${2:-7 days ago}" ;;
  --ips)     cmd_ips "${2:-7 days ago}" ;;
  --today)   cmd_default today ;;
  --since)   cmd_default "${2:-7 days ago}" ;;
  --failed)  cmd_failed "${2:-20}" ;;
  --watch)   cmd_watch ;;
  --record)  cmd_record ;;
  --help|-h) usage ;;
  "")        cmd_default ;;
  *)         usage ;;
esac
MONITOR_EOF
  chmod 0755 /usr/local/bin/ssh-monitor.sh

  cat > /etc/cron.d/ssh-monitor <<'CRON_EOF'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root flock -n /var/lock/ssh-monitor.lock /usr/local/bin/ssh-monitor.sh --record >/dev/null 2>&1
CRON_EOF
  chmod 0644 /etc/cron.d/ssh-monitor

  install -d -o root -g root -m 0750 /var/lib/ssh-monitor
  touch /var/log/ssh-logins.log
  chmod 0640 /var/log/ssh-logins.log
  ok "SSH 监控已安装：ssh-monitor.sh（--help 查看用法），审计日志 /var/log/ssh-logins.log"
}

start_docker() {
  if systemctl is-active --quiet docker; then
    systemctl restart docker
  else
    systemctl enable --now docker
  fi
  if systemctl is-active --quiet docker; then
    ok "Docker 已启动"
  else
    warn "Docker 未能成功启动，请检查：journalctl -u docker --no-pager -n 50"
  fi
}

summary() {
  echo
  ok "========== 服务器初始化完成 =========="
  PRETTY_NAME="$(. /etc/os-release && echo "$PRETTY_NAME")"
  info "系统: $PRETTY_NAME / 内核: $(uname -r)"
  info "IP 地址: $(hostname -I)"
  echo
  info "服务状态:"
  systemctl --no-pager status caddy --lines=0 | head -n 3 || true
  systemctl --no-pager status docker --lines=0 | head -n 3 || true
  echo
  info "iptables INPUT 规则:"
  iptables -L INPUT -n --line-numbers
  echo
  info "fail2ban（sshd jail）:"
  fail2ban-client status sshd 2>/dev/null | grep 'Currently banned' || true
  info "SSH 监控: ssh-monitor.sh --help / 审计日志 /var/log/ssh-logins.log（每分钟自动追加）"
  echo
  warn "用户 $INIT_USER 需重新登录后 docker 命令才无需 sudo"
  warn "SSH 已禁用密码登录，请确保本机私钥可正常使用后再断开当前连接"
  warn "请在 Oracle 云控制台的安全列表（Security List/NSG）中放行 80 和 443 端口"
}

main() {
  check_root
  check_os
  update_system
  install_base_tools
  setup_ssh_hardening
  setup_caddy
  setup_docker
  setup_bbr
  setup_firewall
  setup_journald_persist
  setup_fail2ban
  setup_ssh_monitor
  start_docker
  summary
}

main "$@"
