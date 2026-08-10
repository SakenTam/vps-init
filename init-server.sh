#!/usr/bin/env bash
set -euo pipefail

SSH_PORT=22
WEB_PORTS="80 443"
ALLOW_PING=1
INIT_USER="${SUDO_USER:-ubuntu}"

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
  info "安装 Caddy..."
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y caddy
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

setup_firewall() {
  info "配置 iptables 防火墙（INPUT 仅开放 ${SSH_PORT}/$(echo "$WEB_PORTS" | tr ' ' '/')）..."
  export DEBIAN_FRONTEND=noninteractive
  echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
  echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
  apt-get install -y iptables-persistent > /dev/null
  systemctl enable netfilter-persistent > /dev/null 2>&1 || true

  iptables -P INPUT ACCEPT
  iptables -F
  iptables -X || true

  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
  for p in $WEB_PORTS; do
    iptables -A INPUT -p tcp --dport "$p" -j ACCEPT
  done
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
    if [ "$ALLOW_PING" = "1" ]; then
      ip6tables -A INPUT -p icmpv6 --icmpv6-type echo-request -j ACCEPT
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
  systemctl --no-pager status caddy --lines=0 | head -n 3
  systemctl --no-pager status docker --lines=0 | head -n 3
  echo
  info "iptables INPUT 规则:"
  iptables -L INPUT -n --line-numbers
  echo
  warn "用户 $INIT_USER 需重新登录后 docker 命令才无需 sudo"
  warn "请在 Oracle 云控制台的安全列表（Security List/NSG）中放行 80 和 443 端口"
}

main() {
  check_root
  check_os
  update_system
  install_base_tools
  setup_caddy
  setup_docker
  setup_firewall
  start_docker
  summary
}

main "$@"
