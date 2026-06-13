#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo -e "\033[31m❌ 权限被拒绝: 卸载 IP-Sentinel 需要 root 权限。\033[0m"
  echo -e "💡 请切换到 root 用户后重新运行指令。"
  exit 1
fi

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"

echo "========================================================"
echo "      🗑️ 准备卸载 IP-Sentinel (边缘节点 Agent)"

if [ -f "$CONFIG_FILE" ]; then
    CURRENT_VER=$(grep "^AGENT_VERSION=" "$CONFIG_FILE" | cut -d'"' -f2)
    [ -n "$CURRENT_VER" ] && echo "        📍 目标版本: v${CURRENT_VER}"
fi
echo "========================================================"

echo "正在停止并删除 Systemd 服务..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl kill --signal=SIGKILL ip-sentinel-agent-daemon.service >/dev/null 2>&1 || true
    systemctl disable --now ip-sentinel-runner.service ip-sentinel-runner.timer \
        ip-sentinel-updater.service ip-sentinel-updater.timer \
        ip-sentinel-report.service ip-sentinel-report.timer \
        ip-sentinel-agent-daemon.service >/dev/null 2>&1
    rm -f /etc/systemd/system/ip-sentinel-runner.service
    rm -f /etc/systemd/system/ip-sentinel-runner.timer
    rm -f /etc/systemd/system/ip-sentinel-updater.service
    rm -f /etc/systemd/system/ip-sentinel-updater.timer
    rm -f /etc/systemd/system/ip-sentinel-report.service
    rm -f /etc/systemd/system/ip-sentinel-report.timer
    rm -f /etc/systemd/system/ip-sentinel-agent-daemon.service
    systemctl daemon-reload
    systemctl reset-failed
fi

echo "正在终止后台守护进程与所有任务..."
pkill -9 -f "tg_daemon.sh" >/dev/null 2>&1
pkill -9 -f "agent_daemon.sh" >/dev/null 2>&1
pkill -9 -f "python3.*webhook.py" >/dev/null 2>&1
pkill -9 -f "webhook.py" >/dev/null 2>&1
pkill -9 -f "runner.sh" >/dev/null 2>&1
pkill -9 -f "updater.sh" >/dev/null 2>&1
pkill -9 -f "tg_report.sh" >/dev/null 2>&1
pkill -9 -f "mod_google.sh" >/dev/null 2>&1
pkill -9 -f "mod_trust.sh" >/dev/null 2>&1
pkill -9 -f "sentinel_scheduler.sh" >/dev/null 2>&1

echo "正在清理系统定时任务 (Cron)..."
# 避免写入临时文件以提升安全性
crontab -l 2>/dev/null | grep -v "ip_sentinel" | crontab - >/dev/null 2>&1 || true

for CRON_FILE in "/var/spool/cron/crontabs/root" "/etc/crontabs/root"; do
    if [ -f "$CRON_FILE" ]; then
        grep -v "ip_sentinel" "$CRON_FILE" > "${CRON_FILE}.tmp" 2>/dev/null || true
        cat "${CRON_FILE}.tmp" > "$CRON_FILE" 2>/dev/null || true
        rm -f "${CRON_FILE}.tmp" 2>/dev/null
    fi
done
rm -f /etc/local.d/ip_sentinel.start 2>/dev/null
rm -f /etc/local.d/ip_sentinel_scheduler.start 2>/dev/null

if grep -q "sentinel_scheduler.sh" /etc/profile 2>/dev/null; then
    sed -i '/sentinel_scheduler\.sh/d' /etc/profile 2>/dev/null || true
fi

echo "正在清理本地防火墙规则..."
if [ -f "$CONFIG_FILE" ]; then
    AGENT_PORT=$(grep "^AGENT_PORT=" "$CONFIG_FILE" | cut -d'"' -f2)
    if [ -n "$AGENT_PORT" ]; then
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw active; then
            ufw delete allow "$AGENT_PORT"/tcp >/dev/null 2>&1
            echo -e " ✅ \033[32mUFW 防火墙规则清理成功 (端口: $AGENT_PORT)。\033[0m"
        elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld | grep -qw active; then
            firewall-cmd --zone=public --remove-port="$AGENT_PORT"/tcp --permanent >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
            echo -e " ✅ \033[32mFirewalld 规则清理成功。\033[0m"
        else
            local fw_removed=false
            if command -v iptables >/dev/null 2>&1; then
                # iptables 仅删除单条匹配规则，使用循环清理可能存在的重复规则
                while iptables -C INPUT -p tcp --dport "$AGENT_PORT" -j ACCEPT >/dev/null 2>&1; do
                    iptables -D INPUT -p tcp --dport "$AGENT_PORT" -j ACCEPT
                    fw_removed=true
                done
            fi
            if command -v ip6tables >/dev/null 2>&1; then
                while ip6tables -C INPUT -p tcp --dport "$AGENT_PORT" -j ACCEPT >/dev/null 2>&1; do
                    ip6tables -D INPUT -p tcp --dport "$AGENT_PORT" -j ACCEPT
                    fw_removed=true
                done
            fi
            
            if [ "$fw_removed" = true ]; then
                echo -e " ✅ \033[32mIptables 规则清理成功。\033[0m"
            fi
        fi
    fi
fi

echo "正在清理程序文件与配置..."
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
fi

echo "========================================================"
echo "✅ 卸载完成。"
echo "========================================================"
