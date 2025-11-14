#!/bin/bash

# -----------------------------------------------------------------------------
# 适用于 Ubuntu 24 的交互式 VPS 初始化脚本 (Root 运行版) v8
#
# 变更日志:
# 1. (v8) [新增] 系统状态检查函数，显示 BBR/Swap/时区/Docker 状态
# 2. (v8) [新增] 日志记录功能，所有操作记录到 /var/log/vps-init-*.log
# 3. (v8) [增强] 错误处理，添加磁盘空间检查和管道错误捕获
# 4. (v8) [新增] 系统兼容性检查，验证 Ubuntu 版本
# 5. (v8) [优化] 交互体验，添加"查看系统状态"选项
# 6. (v8) [优化] APT 性能，静默输出和禁用建议包
# 7. (v7) [新增] 添加 'task_set_timezone' 函数，用于设置时区为 Asia/Shanghai
# 8. (v6) [优化] Docker 安装改用官方 'get.docker.com' 脚本
# -----------------------------------------------------------------------------

# 启用管道错误捕获
set -o pipefail

# --- 日志配置 ---
LOG_FILE="/var/log/vps-init-$(date +%Y%m%d-%H%M%S).log"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 助手函数 ---
log_and_echo() {
    local message="$1"
    echo -e "$message" | tee -a "$LOG_FILE"
}

info() {
    log_and_echo "${BLUE}[INFO] $1${NC}"
}

success() {
    log_and_echo "${GREEN}[SUCCESS] $1${NC}"
}

warn() {
    log_and_echo "${YELLOW}[WARNING] $1${NC}"
}

error() {
    log_and_echo "${RED}[ERROR] $1${NC}" >&2
}

backup_config() {
    local file="$1"
    if [ -f "$file" ]; then
        cp "$file" "${file}.bak-$(date +%Y%m%d-%H%M%S)"
        info "已备份: $file"
    fi
}

# --- 系统状态检查函数 ---
check_system_status() {
    echo -e "\n${BLUE}========== 当前系统状态 ==========${NC}"
    
    # BBR 状态
    echo -e "\n${YELLOW}[BBR 状态]${NC}"
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        echo -e "${GREEN}✓ BBR 已启用${NC}"
    else
        echo -e "${RED}✗ BBR 未启用${NC}"
    fi
    
    # Swap 状态
    echo -e "\n${YELLOW}[Swap 状态]${NC}"
    if swapon -s | grep -q '/swapfile'; then
        local swap_size=$(swapon -s | grep '/swapfile' | awk '{print $3}')
        echo -e "${GREEN}✓ Swapfile 已激活 ($(numfmt --to=iec-i --suffix=B $((swap_size * 1024))))${NC}"
        echo "  Swappiness: $(cat /proc/sys/vm/swappiness)"
    else
        echo -e "${RED}✗ Swapfile 未配置${NC}"
    fi
    
    # 时区状态
    echo -e "\n${YELLOW}[时区设置]${NC}"
    local current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || timedatectl | grep "Time zone" | awk '{print $3}')
    if [ "$current_tz" == "Asia/Shanghai" ]; then
        echo -e "${GREEN}✓ 时区: $current_tz${NC}"
    else
        echo -e "${YELLOW}◉ 时区: $current_tz (非 Asia/Shanghai)${NC}"
    fi
    echo "  当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    
    # Docker 状态
    echo -e "\n${YELLOW}[Docker 状态]${NC}"
    if command -v docker >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Docker 已安装 ($(docker --version | cut -d' ' -f3 | tr -d ','))${NC}"
        if systemctl is-active --quiet docker 2>/dev/null; then
            echo -e "${GREEN}  ✓ Docker 服务运行中${NC}"
        else
            echo -e "${RED}  ✗ Docker 服务未运行${NC}"
        fi
        if id "ubuntu" >/dev/null 2>&1 && groups "ubuntu" | grep -q "\bdocker\b"; then
            echo -e "${GREEN}  ✓ ubuntu 用户在 docker 组${NC}"
        fi
    else
        echo -e "${RED}✗ Docker 未安装${NC}"
    fi
    
    # UFW 状态
    echo -e "\n${YELLOW}[UFW 防火墙]${NC}"
    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -q "Status: active"; then
            echo -e "${GREEN}✓ UFW 已启用${NC}"
            echo "  活动规则:"
            ufw status numbered | grep -E "(22|80|443)" | sed 's/^/  /'
        else
            echo -e "${YELLOW}◉ UFW 已安装但未启用${NC}"
        fi
    else
        echo -e "${RED}✗ UFW 未安装${NC}"
    fi
    
    # Zsh 状态
    echo -e "\n${YELLOW}[Shell 配置]${NC}"
    for user in root ubuntu; do
        if id "$user" >/dev/null 2>&1; then
            local user_shell=$(getent passwd "$user" | cut -d: -f7)
            if [[ "$user_shell" == *"zsh"* ]]; then
                echo -e "${GREEN}✓ $user: zsh${NC}"
            else
                echo -e "${YELLOW}◉ $user: $user_shell${NC}"
            fi
        fi
    done
    
    # 磁盘空间
    echo -e "\n${YELLOW}[磁盘空间]${NC}"
    local available_gb=$(df -BG / | tail -1 | awk '{print $4}' | tr -d 'G')
    if [ "$available_gb" -gt 5 ]; then
        echo -e "${GREEN}✓ 可用空间: ${available_gb}G${NC}"
    else
        echo -e "${YELLOW}◉ 可用空间: ${available_gb}G (建议 >5G)${NC}"
    fi
    
    echo -e "\n${BLUE}=================================${NC}\n"
}

# --- 安全检查 (Root 运行 + 系统版本) ---
pre_check() {
    info "开始执行安全检查..."
    
    # 检查 root 权限
    if [ "$(id -u)" -ne 0 ]; then
        error "请使用 root 用户 (例如: sudo -i) 运行此脚本。"
        exit 1
    fi
    
    # 检查系统版本
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        if [[ "$ID" != "ubuntu" ]]; then
            warn "此脚本专为 Ubuntu 设计，当前系统: $PRETTY_NAME"
            read -p "是否继续? (y/N) " confirm
            [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 0
        elif [[ ! "$VERSION_ID" =~ ^2[2-4] ]]; then
            warn "此脚本专为 Ubuntu 22-24 设计，当前版本: $VERSION_ID"
            read -p "是否继续? (y/N) " confirm
            [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 0
        fi
        info "系统版本: $PRETTY_NAME"
    fi
    
    success "以 Root 权限运行，检查通过。"
    info "日志文件: $LOG_FILE"
}

# --- 任务函数 (模块化 & 幂等) ---

# 1. 安装基础包 (性能优化版)
task_install_base() {
    info "1. 开始安装基础软件包..."
    
    # 设置非交互模式
    export DEBIAN_FRONTEND=noninteractive
    
    info "更新软件包列表..."
    if ! apt-get update -qq 2>&1 | tee -a "$LOG_FILE" | grep -v "^Get:" | grep -v "^Reading"; then
        error "apt-get update 失败"
        return 1
    fi
    
    info "安装软件包..."
    if ! apt-get install -y -qq --no-install-recommends \
        neofetch btop vim wget curl git unzip \
        2>&1 | tee -a "$LOG_FILE" | grep -v "^Get:" | grep -v "^Reading" | grep -v "^Selecting"; then
        error "软件包安装失败"
        return 1
    fi
    
    success "基础软件包安装完成。"
}

# 2. 配置 2G Swapfile (增强错误处理)
task_setup_swapfile() {
    info "2. 开始配置 2G Swapfile..."
    
    # 检查磁盘空间
    local available_space=$(df / | tail -1 | awk '{print $4}')
    if [ "$available_space" -lt 2097152 ]; then  # 2GB in KB
        error "磁盘空间不足 (需要 2GB)，无法创建 Swapfile"
        return 1
    fi
    
    if swapon -s | grep -q '/swapfile'; then
        info "Swapfile 似乎已激活。"
    else
        if [ ! -f /swapfile ]; then
            info "创建 /swapfile (2G)..."
            if ! fallocate -l 2G /swapfile; then
                error "创建 Swapfile 失败"
                return 1
            fi
            chmod 600 /swapfile
            if ! mkswap /swapfile 2>&1 | tee -a "$LOG_FILE"; then
                error "格式化 Swapfile 失败"
                return 1
            fi
        else
            info "/swapfile 文件已存在。"
        fi
        
        if ! swapon /swapfile; then
            error "激活 Swapfile 失败"
            return 1
        fi
        info "Swapfile 已激活。"
    fi
    
    if ! grep -q "swapfile" /etc/fstab; then
        info "添加 Swapfile 到 /etc/fstab 以实现开机自启..."
        backup_config /etc/fstab
        echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
    else
        info "/etc/fstab 中已包含 Swapfile 配置。"
    fi
    
    if ! grep -q "vm.swappiness=60" /etc/sysctl.conf; then
        backup_config /etc/sysctl.conf
        echo 'vm.swappiness=60' | tee -a /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
    
    success "Swapfile 配置完成。"
}

# 3. 配置 Zsh (双目标: root + ubuntu)
_install_zsh_for_user() {
    local ZIM_USER="$1"
    local ZIM_HOME="$2"

    if ! id "$ZIM_USER" >/dev/null 2>&1; then
        warn "用户 $ZIM_USER 不存在。跳过为其配置 Zsh。"
        return 1
    fi
    if [ ! -d "$ZIM_HOME" ]; then
        warn "用户 $ZIM_USER 的家目录 $ZIM_HOME 不存在。跳过。"
        return 1
    fi
    
    info "--- 正在为 [$ZIM_USER] (家: $ZIM_HOME) 配置 Zsh ---"

    if [ ! -d "$ZIM_HOME/.zim" ]; then
        info "为 $ZIM_USER 预配置 p10k 模块..."
        sudo -u "$ZIM_USER" touch "$ZIM_HOME/.zimrc"
        if ! sudo -u "$ZIM_USER" grep -q "romkatv/powerlevel10k" "$ZIM_HOME/.zimrc"; then
            echo "zmodule romkatv/powerlevel10k" | sudo -u "$ZIM_USER" tee -a "$ZIM_HOME/.zimrc" > /dev/null
        fi

        info "为 $ZIM_USER 运行 Zim 框架安装器..."
        if ! sudo -u "$ZIM_USER" ZDOTDIR="$ZIM_HOME" zsh -c "curl -fsSL https://raw.githubusercontent.com/zimfw/install/master/install.zsh | zsh" 2>&1 | tee -a "$LOG_FILE"; then
            error "Zim 安装失败 (用户: $ZIM_USER)"
            return 1
        fi
        
        info "Zim 框架及 P10k 已为 $ZIM_USER 安装。"
    else
        info "Zim 框架已为 $ZIM_USER 安装。"
    fi

    if [ "$(getent passwd "$ZIM_USER" | cut -d: -f7)" != "$(which zsh)" ]; then
        info "更改 $ZIM_USER 的默认 shell 为 zsh..."
        chsh -s "$(which zsh)" "$ZIM_USER"
        success "[$ZIM_USER] 的 shell 已更改。"
    else
        info "[$ZIM_USER] 的默认 shell 已经是 zsh。"
    fi
}

task_configure_zsh() {
    info "3. 开始配置 Zsh, Zim 和 Powerlevel10k..."
    
    if ! command -v zsh >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y zsh 2>&1 | tee -a "$LOG_FILE"
    else
        info "Zsh 已安装。"
    fi

    if [ -f "/etc/zsh/zshrc" ] && grep -q "^\s*compinit" "/etc/zsh/zshrc"; then
        info "修补 /etc/zsh/zshrc 以防止 'compinit' 冲突..."
        backup_config /etc/zsh/zshrc
        sed -i 's/^\s*compinit/#&/' /etc/zsh/zshrc
    fi

    _install_zsh_for_user "root" "/root"
    _install_zsh_for_user "ubuntu" "/home/ubuntu"

    success "Zsh 双目标配置完成。"
    info "请相关用户 (root, ubuntu) 退出并重新登录以启用 Zsh。"
}

# 4. 开启 BBR
task_optimize_network_bbr() {
    info "4. 开始启用 BBR..."
    local BBR_CONF_1="net.core.default_qdisc=fq"
    local BBR_CONF_2="net.ipv4.tcp_congestion_control=bbr"
    
    if grep -q "$BBR_CONF_2" /etc/sysctl.conf; then
        info "BBR 似乎已配置。"
    else
        info "写入 BBR 配置到 /etc/sysctl.conf..."
        backup_config /etc/sysctl.conf
        echo "$BBR_CONF_1" | tee -a /etc/sysctl.conf
        echo "$BBR_CONF_2" | tee -a /etc/sysctl.conf
        info "应用配置..."
        sysctl -p 2>&1 | tee -a "$LOG_FILE"
    fi
    
    info "检查 BBR 状态..."
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        success "BBR 已成功启用。"
    else
        warn "BBR 未能立即启用，可能需要重启系统 (reboot)。"
    fi
}

# 5. 配置 UFW 防火墙
task_configure_ufw() {
    info "5. 开始配置 UFW 防火墙..."
    if ! command -v ufw >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y ufw 2>&1 | tee -a "$LOG_FILE"
    fi
    
    ufw default deny incoming
    ufw default allow outgoing
    
    info "设置 UFW 规则 (Limit 22/tcp, Allow 80/tcp, Allow 443/tcp)..."
    ufw limit 22/tcp comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    
    info "启用 UFW..."
    if ufw --force enable 2>&1 | tee -a "$LOG_FILE"; then
        success "UFW 已启用并配置完成。"
        ufw status verbose | tee -a "$LOG_FILE"
    else
        error "UFW 启用失败。"
        return 1
    fi
}

# 6. (可选) 安装 Docker
task_install_docker_optional() {
    info "6. 检查是否安装 Docker..."
    
    read -p "您是否希望安装 Docker? (y/N) " choice
    case "$choice" in 
      y|Y )
        if [ -f "/usr/bin/docker" ]; then
            info "Docker 已安装 (/usr/bin/docker 存在)。"
            if id "ubuntu" >/dev/null 2>&1 && ! groups "ubuntu" | grep -q "\bdocker\b"; then
                info "Docker 已安装，但 'ubuntu' 用户不在 docker 组中。正在添加..."
                usermod -aG docker "ubuntu"
                warn "用户 'ubuntu' 已添加到 docker 组。请重新登录以生效。"
            fi
        else
            info "开始使用 Docker 官方脚本安装 Docker..."
            
            if ! curl -fsSL https://get.docker.com -o get-docker.sh 2>&1 | tee -a "$LOG_FILE"; then
                error "下载 Docker 安装脚本失败。"
                return 1
            fi
            
            if [ ! -f "get-docker.sh" ]; then
                error "Docker 安装脚本文件不存在。"
                return 1
            fi
            
            if ! sh get-docker.sh 2>&1 | tee -a "$LOG_FILE"; then
                error "Docker 安装失败。"
                rm -f get-docker.sh
                return 1
            fi
            rm -f get-docker.sh
            
            if [ ! -f "/usr/bin/docker" ]; then
                 error "Docker 安装失败。请检查日志。"
                 return 1
            fi
            
            info "启动并启用 Docker 服务..."
            systemctl enable docker 2>&1 | tee -a "$LOG_FILE"
            systemctl start docker 2>&1 | tee -a "$LOG_FILE"
            
            if id "ubuntu" >/dev/null 2>&1; then
                info "将用户 'ubuntu' 添加到 'docker' 组..."
                usermod -aG docker "ubuntu"
            fi
            
            success "Docker (及 Docker Compose) 安装完成。"
            warn "用户 'ubuntu' 需要退出并重新登录，才能无需 sudo 运行 docker 命令。"
        fi
        ;;
      * )
        info "跳过安装 Docker。"
        ;;
    esac
}

# 7. 更改时区
task_set_timezone() {
    info "7. 更改时区为 Asia/Shanghai..."
    local TARGET_TZ="Asia/Shanghai"
    
    local current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || timedatectl | grep "Time zone" | awk '{print $3}')
    
    if [ "$current_tz" == "$TARGET_TZ" ]; then
        info "时区已是 $TARGET_TZ。"
    else
        if timedatectl set-timezone $TARGET_TZ 2>&1 | tee -a "$LOG_FILE"; then
            info "时区已设置为 $TARGET_TZ。"
        else
            error "设置时区失败。"
            return 1
        fi
    fi
    
    info "验证当前时间："
    timedatectl | grep "Time zone" | tee -a "$LOG_FILE"
    success "时区设置完成。"
}

# --- 菜单系统 ---

run_all_tasks() {
    info "--- 开始执行全部初始化任务 ---"
    task_install_base
    task_setup_swapfile
    task_configure_zsh
    task_optimize_network_bbr
    task_configure_ufw
    task_install_docker_optional 
    task_set_timezone
    success "--- 所有任务已执行完毕 ---"
    info "查看完整日志: cat $LOG_FILE"
}

show_submenu() {
    while true; do
        echo -e "\n${YELLOW}--- 分类安装菜单 ---${NC}"
        echo "1. 安装基础包 (neofetch, btop, git...)"
        echo "2. 配置 2G Swapfile (硬盘交换)"
        echo "3. 配置 Zsh (为 root 和 ubuntu)"
        echo "4. 启用 BBR 网络优化"
        echo "5. 配置 UFW 防火墙 (22, 80, 443)"
        echo "6. (可选) 安装 Docker (官方脚本)"
        echo "7. 更改时区 (Asia/Shanghai)"
        echo "-------------------------"
        echo "b. 返回主菜单"
        echo "q. 退出脚本"
        
        read -p "请输入选项 [1-7, b, q]: " sub_choice
        
        case $sub_choice in
            1) task_install_base ;;
            2) task_setup_swapfile ;;
            3) task_configure_zsh ;;
            4) task_optimize_network_bbr ;;
            5) task_configure_ufw ;;
            6) task_install_docker_optional ;;
            7) task_set_timezone ;;
            b) break ;; 
            q) exit 0 ;;
            *) error "无效选项。" ;;
        esac
        
        if [ "$sub_choice" != "b" ]; then
             read -p "任务完成。按 Enter 键返回子菜单..."
        fi
    done
}

show_main_menu() {
    while true; do
        echo -e "\n${GREEN}=========================================${NC}"
        echo -e "${GREEN}    Ubuntu 24 VPS 自动化初始化脚本${NC}"
        echo -e "${GREEN}        (必须以 Root 身份运行)${NC}"
        echo -e "${GREEN}=========================================${NC}"
        echo "请选择您的操作模式:"
        echo ""
        echo "0. 查看系统当前状态"
        echo "1. 安装全部所需 (推荐首次运行)"
        echo "2. 按分类安装 (选择性执行任务)"
        echo "q. 退出"
        echo ""
        read -p "请输入选项 [0-2, q]: " main_choice
        
        case $main_choice in
            0)
                check_system_status
                ;;
            1)
                check_system_status
                read -p "查看系统状态后，是否继续执行全部任务? (y/N) " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    run_all_tasks
                    break
                fi
                ;;
            2)
                show_submenu
                ;;
            q)
                exit 0
                ;;
            *)
                error "无效选项，请重新输入。"
                ;;
        esac
    done
}

# --- 脚本主入口 ---
main() {
    pre_check
    show_main_menu
    info "初始化脚本执行完毕。"
    info "日志文件保存在: $LOG_FILE"
}

# 启动脚本
main