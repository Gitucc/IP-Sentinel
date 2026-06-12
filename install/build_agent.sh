#!/bin/bash

# ==========================================================
# 模块名称: build_agent.sh (Orchestrator 编排大管家)
# 核心功能: 严格遵循原版 install.sh 判定树时序，实现无损热更新
# ==========================================================

# 传递中断引信
trap 'exit 1' INT QUIT TERM

# 激活终端退格自适应，防止 SSH 误触产生 ^H / ^? 控制字符
stty erase ^H 2>/dev/null || true
stty erase '^?' 2>/dev/null || true

# 模拟终端物理退格与 ANSI 控制码处理，从数据流层面修正退格污染
process_backspaces() {
    local input="$1"
    local output=""
    local i
    for (( i=0; i<${#input}; i++ )); do
        local char="${input:i:1}"
        if [[ "$char" == $'\x08' || "$char" == $'\x7f' ]]; then
            output="${output%?}"
        else
            output+="$char"
        fi
    done
    local ansi_pattern=$'\x1b''\[[0-9;]*[a-zA-Z~]'
    while [[ "$output" =~ $ansi_pattern ]]; do
        output="${output//"${BASH_REMATCH[0]}"/}"
    done
    echo "$output"
}

# 为了解决 SSH 客户端因终端映射配置差异而导致的退格键转换为控制字符（如 ^H、^?）并破坏白名单及 Token 配置文件的缺陷，
# 引入统一的输入数据过滤器与二次确认交互逻辑。此机制可在字符解析和二次交互两个维度同时拦截错误输入。
safe_read_input() {
    local var_name="$1"
    local prompt_msg="$2"
    local default_val="$3"
    local val_type="$4"
    local raw_val=""
    local clean_val=""
    local confirm_needed="false"

    if [[ "$val_type" == "chatid" || "$val_type" == "token" || "$val_type" == "port" || "$val_type" == "ip" || "$val_type" == "any" ]]; then
        confirm_needed="true"
    fi

    while true; do
        if ! read -e -p "$prompt_msg" raw_val; then
            echo -e "\n\033[31m❌ 输入通道已断开，安装终止。\033[0m"
            exit 130
        fi
        clean_val=$(process_backspaces "$raw_val")
        clean_val=$(echo "$clean_val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        
        if [ -z "$clean_val" ] && [ -n "$default_val" ]; then
            clean_val="$default_val"
        fi

        local is_valid=true
        case "$val_type" in
            yn)
                if [[ -z "$clean_val" ]]; then
                    clean_val="$default_val"
                fi
                if [[ ! "$clean_val" =~ ^[YyNn]$ ]]; then
                    echo -e "\033[31m⚠️ 输入无效，请输入 y 或 n。\033[0m"
                    is_valid=false
                fi
                ;;
            range:*)
                local min=$(echo "$val_type" | cut -d: -f2)
                local max=$(echo "$val_type" | cut -d: -f3)
                if [[ ! "$clean_val" =~ ^[0-9]+$ ]] || (( clean_val < min || clean_val > max )); then
                    echo -e "\033[31m⚠️ 输入无效，请输入介于 $min 到 $max 之间的数字。\033[0m\n"
                    is_valid=false
                fi
                ;;
            chatid)
                clean_val=$(echo "$clean_val" | tr -cd '0-9-')
                if [ -z "$clean_val" ]; then
                    echo -e "\033[31m⚠️ Chat ID 不能为空，且仅限数字与负号，请重新输入。\033[0m"
                    is_valid=false
                fi
                ;;
            token)
                clean_val=$(echo "$clean_val" | tr -d '[:space:]' | tr -cd 'a-zA-Z0-9_:-')
                if [ -z "$clean_val" ]; then
                    echo -e "\033[31m⚠️ Token 不能为空，且只允许字母、数字及下划线/冒号/减号，请重新输入。\033[0m"
                    is_valid=false
                fi
                ;;
            port)
                if [[ ! "$clean_val" =~ ^[0-9]+$ ]] || (( clean_val < 1 || clean_val > 65535 )); then
                    echo -e "\033[31m⚠️ 端口范围应为 1-65535。\033[0m"
                    is_valid=false
                fi
                ;;
            ip)
                clean_val=$(echo "$clean_val" | tr -cd 'a-fA-F0-9.:[]')
                if [ -z "$clean_val" ]; then
                    echo -e "\033[31m⚠️ IP 地址不能为空，请重新输入。\033[0m"
                    is_valid=false
                fi
                ;;
            any)
                clean_val=$(echo "$clean_val" | tr -d '"'\''\`\$\|&;<>')
                ;;
        esac

        if [ "$is_valid" = true ]; then
            if [ "$confirm_needed" = "true" ]; then
                echo -e "💡 确认输入为: \033[36m$clean_val\033[0m"
                if ! read -e -p "❓ 确认无误？(y/n, 默认y): " confirm_yn; then
                    echo -e "\n\033[31m❌ 输入通道已断开，安装终止。\033[0m"
                    exit 130
                fi
                confirm_yn=$(process_backspaces "$confirm_yn")
                confirm_yn=$(echo "$confirm_yn" | tr -d '[:space:]')
                if [[ -z "$confirm_yn" || "$confirm_yn" =~ ^[Yy]$ ]]; then
                    eval "$var_name=\$clean_val"
                    break
                fi
            else
                eval "$var_name=\$clean_val"
                break
            fi
        fi
    done
}

MODULES=(
    "env_setup.sh"
    "ui_menu.sh"
    "net_engine.sh"
    "sys_daemon.sh"
)

# 1. 串行拉取子模块资产
for mod in "${MODULES[@]}"; do
    curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/install/${mod}?t=$(date +%s)" -o "${SECURE_TMP}/${mod}"
    if [ ! -s "${SECURE_TMP}/${mod}" ]; then
        echo -e "\033[31m❌ 致命错误：依赖模块 [${mod}] 装载失败！\033[0m"
        exit 1
    fi
    source "${SECURE_TMP}/${mod}"
done

# ==========================================================
# 2. 核心业务原子流 (100% 忠实于原版 install.sh 执行时序)
# ==========================================================

# [环境预检阶段]
do_env_precheck       # 架构预检、系统级诊断 (原版第 26-55 行)
do_fetch_version      # 动态解析远端版本约束 (原版第 59-66 行)
do_install_deps       # 多分支包管理器嗅探与系统补全 (原版第 70-137 行)

# [菜单与策略拦截阶段]
do_fetch_map          # LBS 地理图谱树预载 (原版第 141-146 行)
do_handle_menu        # 区分全新安装、平滑升级与一键卸载 (原版第 149-188 行)

# [物理清洗阶段]
do_clean_env          # 幽灵进程抹除、无损清空与数据保护 (原版第 192-225 行)

# [配置生成阶段 (仅限全新安装)]
do_interactive_setup  # 逐级锁定战区城市、联控配置、端口探测 (原版第 229-373 行)

# [网络雷达与身份装配阶段]
do_network_probe      # 冗余双栈探测、网卡锁、WARP假公网隔离 (原版第 375-430 行)
do_assemble_fallback  # 智能多宿主容灾弹匣装填、主键别名分离 (原版第 432-475 行)
do_write_config       # 固化本地本地 config.conf 档案 (原版第 477-512 行)

# [老节点热重载平滑升级阶段 (仅限升级模式)]
do_smooth_migrate     # 强行覆写、重铸双栈容灾装甲 (原版第 516-590 行)

# [核心引擎原子覆写阶段]
do_deploy_core        # 双缓冲防变砖下载域、物理覆写核心文件 (原版第 594-620 行)

# [进程守护与首播激活阶段]
do_inject_daemon      # Systemd/Alpine 看门狗死循环双重注入 (原版第 622-728 行)
do_final_report       # 首播暗号同步、Markdown防断开下划线发送 (原版第 732-793 行)
do_show_summary       # 防火墙端口提示、装机量统计、开源 Star 推广 (原版第 795-832 行)

exit 0