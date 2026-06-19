#!/bin/bash

trap 'exit 1' INT QUIT TERM

INSTALL_LOG="/opt/ip_sentinel/logs/install_master.log"
mkdir -p "/opt/ip_sentinel/logs"
exec > >(tee -a "$INSTALL_LOG") 2>&1
echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] IP-Sentinel Master 部署流程开始 ==="

MODULES=(
    "env_setup.sh"
    "master_setup.sh"
)

for mod in "${MODULES[@]}"; do
    curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/install/${mod}?t=$(date +%s)" -o "${SECURE_TMP}/${mod}"
    if [ ! -s "${SECURE_TMP}/${mod}" ]; then
        echo -e "\033[31m❌ 致命错误：中枢依赖模块 [${mod}] 装载失败！\033[0m"
        exit 1
    fi
    source "${SECURE_TMP}/${mod}"
done

do_master_env_precheck
do_fetch_master_version
do_master_handle_menu
do_install_deps

do_master_clean_env
do_master_config
do_master_init_db
do_master_deploy_core
do_master_summary

exit 0
