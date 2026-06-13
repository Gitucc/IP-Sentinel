#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo -e "\033[31m❌ 权限被拒绝: 卸载 IP-Sentinel Master 需要 root 权限。\033[0m"
  echo -e "💡 请切换到 root 用户后重新运行指令。"
  exit 1
fi

MASTER_DIR="/opt/ip_sentinel_master"
CONF_FILE="${MASTER_DIR}/master.conf"

echo "========================================================"
echo "      🗑️ 准备卸载 IP-Sentinel Master (控制中枢)"

if [ -f "$CONF_FILE" ]; then
    MASTER_VER=$(grep "^MASTER_VERSION=" "$CONF_FILE" | cut -d'"' -f2)
    [ -n "$MASTER_VER" ] && echo "        📍 目标版本: v${MASTER_VER}"
fi
echo "========================================================"

echo -e "\n⚠️ 警告: 此操作将永久删除包含所有节点档案的 SQLite 数据库！"
read -e -p "确定要继续卸载吗？(y/n) [默认 n]: " CONFIRM_DEL
if [[ ! "$CONFIRM_DEL" =~ ^[Yy]$ ]]; then
    echo "已取消卸载操作。"
    exit 0
fi

echo "正在停止并删除 Systemd 服务..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl kill --signal=SIGKILL ip-sentinel-master.service >/dev/null 2>&1 || true
    systemctl disable --now ip-sentinel-master.service >/dev/null 2>&1
    rm -f /etc/systemd/system/ip-sentinel-master.service
    systemctl daemon-reload
    systemctl reset-failed
fi

echo "正在终止后台中枢调度进程..."
pkill -9 -f "tg_master.sh" >/dev/null 2>&1 || true

echo "正在清理系统定时任务 (Cron)..."
crontab -l 2>/dev/null | grep -v "tg_master.sh" | crontab - >/dev/null 2>&1 || true

echo "正在抹除程序文件、配置文件与数据库..."
if [ -d "$MASTER_DIR" ]; then
    rm -rf "$MASTER_DIR"
fi

echo "========================================================"
echo "✅ 卸载完成。"
echo "========================================================"