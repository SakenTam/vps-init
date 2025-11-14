#!/bin/bash

# -----------------------------------------------------------------------------
# 适用于 Ubuntu 24 的交互式 VPS 初始化脚本 (Root 运行版) v10
#
# 变更日志:
# 1. (v10) [修复] 调整 'task_configure_zsh' 逻辑：
#           - 必须先下载 .p10k.zsh，然后再运行 zimfw install。
#           - 增加文件大小检查 [ -s ] 确保下载不为空。
# 2. (v9) [新增] P10K_CONFIG_URL 变量。
# 3. (v9) [新增] 启动时 'task_check_status' 状态检查。
# -----------------------------------------------------------------------------

# --- [v9] 配置变量 ---
P10K_CONFIG_URL="https://raw.githubusercontent.com/SakenTam/vps-init/refs/heads/main/.p10k.zsh"


# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- 助手函数 ---
info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}
success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}
warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}
error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
}
status_check() {
    local status_name="$1"
    local status_value="$2"
    local status_color="$3"
    printf "    %-10s : %b\n" "$status_name" "${status_color}${status_value}${NC}"
}

# --- 安全检查 (Root 运行) ---
pre_check() {
    info "开始执行安全检查..."
    if [ "$(id -u)" -ne 0 ]; then
        error "请使用 root 用户 (例如: sudo -i) 运行此脚本。"
        exit 1
    fi
    success "以 Root 权限运行，检查通过。"
}

# --- [v9] 启动状态检查 ---
task_check_status() {
    echo -e "\n${CYAN}--- 正在检查当前系统状态 ---${NC}"
    
    # 1. 检查 Swap
    if swapon -s | grep -q '/swapfile'; then
        local swap_size=$(free -h | grep Swap | awk '{print $2}')
        status_check "Swap" "Active ($swap_size)" "$GREEN"
    else
        status_check "Swap" "Inactive" "$YELLOW"
    fi
    
    # 2. 检查 BBR
    local bbr_status=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null)
    if echo "$bbr_status" | grep -q "bbr"; then
        status_check "BBR" "Enabled (bbr)" "$GREEN"
    else
        status_check "BBR" "Disabled" "$YELLOW"
    fi

    # 3. 检查 Docker
    if command -v docker >/dev/null 2>&1; then
        if systemctl is-active --quiet docker; then
             status_check "Docker" "Installed & Running" "$GREEN"
        else
             status_check "Docker" "Installed (Not Running)" "$YELLOW"
        fi
    else
        status_check "Docker" "Not Installed" "$RED"
    fi

    # 4. 检查时区
    local current_tz=$(timedatectl | grep "Time zone" | awk '{print $3}')
    if [ "$current_tz" == "Asia/Shanghai" ]; then
        status_check "Timezone" "$current_tz" "$GREEN"
    else
        status_check "Timezone" "$current_tz (非上海)" "$YELLOW"
    fi
    
    echo -e "${CYAN}----------------------------------${NC}"
}


# --- 任务函数 (模块化 & 幂等) ---

# 1. 安装基础包
task_install_base() {
    info "1. 开始安装基础软件包..."
    apt-get update -qq
    apt-get install -y neofetch btop vim wget curl git unzip
    success "基础软件包安装完成。"
}

# 2. 配置 2G Swapfile
task_setup_swapfile() {
    info "2. 开始配置 2G Swapfile..."
    # (此处省略 v9 中未改动的代码)
    if swapon -s | grep -q '/swapfile'; then
        info "Swapfile 似乎已激活。"
    else
        if [ ! -f /swapfile ]; then
            info "创建 /swapfile (2G)..."
            fallocate -l 2G /swapfile
            chmod 600 /swapfile
            mkswap /swapfile
        else
            info "/swapfile 文件已存在。"
        fi
        swapon /swapfile
        info "Swapfile 已激活。"
    fi
    if ! grep -q "swapfile" /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
    fi
    if ! grep -q "vm.swappiness=60" /etc/sysctl.conf; then
         echo 'vm.swappiness=60' | tee -a /etc/sysctl.conf
         sysctl -p >/dev/null 2>&1
    fi
    success "Swapfile 配置完成。"
}

# 3. 配置 Zsh (双目标: root + ubuntu)
# [v10 修复] 调整 Zsh 和 P10k 的安装顺序
_install_zsh_for_user() {
    local ZIM_USER="$1"
    local ZIM_HOME="$2"
    local P10K_FILE="$ZIM_HOME/.p10k.zsh"

    if ! id "$ZIM_USER" >/dev/null 2>&1; then
        warn "用户 $ZIM_USER 不存在。跳过为其配置 Zsh。"
        return 1
    fi
    if [ ! -d "$ZIM_HOME" ]; then
        warn "用户 $ZIM_USER 的家目录 $ZIM_HOME 不存在。跳过。"
        return 1
    fi
    
    info "--- 正在为 [$ZIM_USER] (家: $ZIM_HOME) 配置 Zsh ---"

    # [v10 修正] 步骤 1：必须先下载 P10k 配置文件
    if [ -n "$P10K_CONFIG_URL" ] && [ "$P10K_CONFIG_URL" != "YOUR_P10K_RAW_URL_HERE" ]; then
        info "--- 正在为 [$ZIM_USER] 下载自定义 .p10k.zsh ---"
        # 作为该用户下载，以确保正确的文件所有权
        if sudo -u "$ZIM_USER" curl -fsSL "$P10K_CONFIG_URL" -o "$P10K_FILE"; then
            # [v10 加固] 验证文件是否下载成功且不为空
            if [ -s "$P10K_FILE" ]; then
                success "已为 [$ZIM_USER] 部署自定义 .p10k.zsh。"
            else
                error "为 [$ZIM_USER] 下载 .p10k.zsh 失败 (文件为空)。"
                sudo -u "$ZIM_USER" rm "$P10K_FILE" # 删除空文件
            fi
        else
            error "为 [$ZIM_USER] 下载 .p10k.zsh 失败 (curl 错误)。将使用 P10k 默认向导。"
        fi
    else
        if [ "$ZIM_USER" == "root" ]; then # 只警告一次
             warn "P10K_CONFIG_URL 未设置。用户首次登录时需要手动配置 P10k。"
        fi
    fi

    # [v10 修正] 步骤 2：现在才运行 Zim 安装
    if [ ! -d "$ZIM_HOME/.zim" ]; then
        info "为 $ZIM_USER 预配置 p10k 模块 (.zimrc)..."
        sudo -u "$ZIM_USER" touch "$ZIM_HOME/.zimrc"
        if ! sudo -u "$ZIM_USER" grep -q "romkatv/powerlevel10k" "$ZIM_HOME/.zimrc"; then
            echo "zmodule romkatv/powerlevel10k" | sudo -u "$ZIM_USER" tee -a "$ZIM_HOME/.zimrc" > /dev/null
        fi

        info "为 $ZIM_USER 运行 Zim 框架安装器..."
        # Zim 安装器现在会检测到 .p10k.zsh 并自动使用它
        sudo -u "$ZIM_USER" ZDOTDIR="$ZIM_HOME" zsh -c "curl -fsSL https://raw.githubusercontent.com/zimfw/install/master/install.zsh | zsh"
        
        info "Zim 框架已为 $ZIM_USER 安装。"
    else
        info "Zim 框架已为 $ZIM_USER 安装。"
    fi

    # [v10 修正] 步骤 3：设置默认 Shell
    if [ "$(getent passwd "$ZIM_USER" | cut -d: -f7)" != "$(which zsh)" ]; then
        info "更改 $ZIM_USER 的默认 shell 为 zsh..."
        chsh -s "$(which zsh)" "$ZIM_USER"
        if [ $? -eq 0 ]; then
             success "[$ZIM_USER] 的 shell 已更改。"
        else
             error "[$ZIM_USER] 的 shell 更改失败。请检查系统日志。"
        fi
    else
        info "[$ZIM_USER] 的默认 shell 已经是 zsh。"
    fi
}

task_configure_zsh() {
    info "3. 开始配置 Zsh, Zim 和 Powerlevel10k..."
    
    if ! command -v zsh >/dev/null 2>&1; then
        apt-get install -y zsh
    else
        info "Zsh 已安装。"
    fi

    if [ -f "/etc/zsh/zshrc" ] && grep -q "^\s*compinit" "/etc/zsh/zshrc"; then
        info "修补 /etc/zsh/zshrc 以防止 'compinit' 冲突..."
        cp /etc/zsh/zshrc /etc/zsh/zshrc.bak-$(date +%F) >/dev/null 2>&1
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
    # (此处省略 v9 中未改动的代码)
    local BBR_CONF_1="net.core.default_qdisc=fq"
    local BBR_CONF_2="net.ipv4.tcp_congestion_control=bbr"
    if grep -q "$BBR_CONF_2" /etc/sysctl.conf; then
        info "BBR 似乎已配置。"
    else
        info "写入 BBR 配置到 /etc/sysctl.conf..."
        echo "$BBR_CONF_1" | tee -a /etc/sysctl.conf
        echo "$BBR_CONF_2" | tee -a /etc/sysctl.conf
        info "应用配置..."
        sysctl -p >/dev/null 2>&1
    fi
    info "检查 BBR 状态..."
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        success "BBR 已成功启用。"
    else
        warn "BBR 未能立即启用，可能需要重启系统 (reboot)。"
    fi
}

# 5. 配置 UFW 防火墙
task_configure_ufw() {
    info "5. 开始配置 UFW 防火墙..."
    # (此处省略 v9 中未改动的代码)
    if ! command -v ufw >/dev/null 2>&1; then
        apt-get install -y ufw
    fi
    ufw default deny incoming
    ufw default allow outgoing
    info "设置 UFW 规则 (Limit 22/tcp, Allow 80/tcp, Allow 443/tcp)..."
    ufw limit 22/tcp comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    info "启用 UFW..."
    if ufw --force enable; then
        success "UFW 已启用并配置完成。"
        ufw status verbose
    else
        error "UFW 启用失败。"
    fi
}

# 6. (可选) 安装 Docker
task_install_docker_optional() {
    info "6. 检查是否安装 Docker..."
    # (此处省略 v9 中未改动的代码)
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
            curl -fsSL https://get.docker.com -o get-docker.sh
            if [ ! -f "get-docker.sh" ]; then
                error "下载 Docker 安装脚本失败。"
                return 1
            fi
            sh get-docker.sh
            rm get-docker.sh
            if [ ! -f "/usr/bin/docker" ]; then
                 error "Docker 安装失败。请检查上面的日志。"
                 return 1
            fi
            info "启动并启用 Docker 服务..."
            systemctl enable docker
            systemctl start docker
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

# 7. [V7 新增] 更改时区
task_set_timezone() {
    info "7. 更改时区为 Asia/Shanghai..."
    # (此处省略 v9 中未改动的代码)
    local TARGET_TZ="Asia/Shanghai"
    local current_tz=$(timedatectl | grep "Time zone" | awk '{print $3}')
    if [ "$current_tz" == "$TARGET_TZ" ]; then
        info "时区已是 $TARGET_TZ。"
    else
        timedatectl set-timezone $TARGET_TZ
        if [ $? -eq 0 ]; then
            info "时区已设置为 $TARGET_TZ。"
        else
            error "设置时区失败。"
            return 1
        fi
    fi
    info "验证当前时间："
    timedatectl | grep "Time zone"
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
    while true;
        do
        clear # 清屏
        echo -e "\n${GREEN}=========================================${NC}"
        echo -e "${GREEN}    Ubuntu 24 VPS 自动化初始化脚本${NC}"
        echo -e "${GREEN}        (必须以 Root 身份运行)${NC}"
        echo -e "${GREEN}=========================================${NC}"
        
        task_check_status # <-- v9 状态检查
        
        echo ""
        echo "请选择您的操作模式:"
        echo "1. 安装全部所需 (推荐首次运行)"
        echo "2. 按分类安装 (选择性执行任务)"
        echo "q. 退出"
        echo ""
        read -p "请输入选项 [1, 2, q]: " main_choice
        
        case $main_choice in
            1)
                run_all_tasks
                break 
                ;;
            2)
                show_submenu
                ;;
            q)
                exit 0
                ;;
            *)
                error "无效选项，请重新输入。"
                sleep 2
                ;;
        esac
    done
}

# --- 脚本主入口 ---
main() {
    pre_check
    show_main_menu
    info "初始化脚本执行完毕。"
}

# 启动脚本
main