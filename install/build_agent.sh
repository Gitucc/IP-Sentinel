#!/bin/bash

trap 'exit 1' INT QUIT TERM

stty erase ^H 2>/dev/null || true
stty erase '^?' 2>/dev/null || true

INSTALL_LOG="/opt/ip_sentinel/logs/install.log"
mkdir -p "/opt/ip_sentinel/logs"
exec > >(tee -a "$INSTALL_LOG") 2>&1
echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] IP-Sentinel Agent 部署流程开始 ==="

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

for mod in "${MODULES[@]}"; do
    curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/install/${mod}?t=$(date +%s)" -o "${SECURE_TMP}/${mod}"
    if [ ! -s "${SECURE_TMP}/${mod}" ]; then
        echo -e "\033[31m❌ 致命错误：依赖模块 [${mod}] 装载失败！\033[0m"
        exit 1
    fi
    source "${SECURE_TMP}/${mod}"
done

do_env_precheck
do_fetch_version
do_install_deps

do_fetch_map
do_handle_menu

do_clean_env

do_interactive_setup

do_network_probe
do_assemble_fallback
do_write_config

do_smooth_migrate

do_deploy_core

do_inject_daemon
do_final_report
do_show_summary

exit 0