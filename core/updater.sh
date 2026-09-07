#!/bin/bash

INSTALL_DIR=${INSTALL_DIR:-/opt/ip_sentinel}
CONFIG_FILE=${CONFIG_FILE:-${INSTALL_DIR}/config.conf}
UA_TIME_FILE=${UA_TIME_FILE:-${INSTALL_DIR}/core/.ua_last_update}

REPO_RAW_URL=${REPO_RAW_URL:-https://raw.githubusercontent.com/Gitucc/IP-Sentinel/main}
CURL_BIN=${CURL_BIN:-curl}

if [ ! -f "$CONFIG_FILE" ]; then
    exit 1
fi
source "$CONFIG_FILE"

if [ "${1:-}" = "--scheduled" ]; then
    STATE_DIR="${INSTALL_DIR}/data/.update_state"
    mkdir -p "$STATE_DIR" || exit 1
    # 安装后的首次检查可能与定时任务重叠，锁要覆盖下载和成功标记写入。
    exec 9>"${STATE_DIR}/lock"
    flock -n 9 || exit 0

    # Cron 使用宿主时区；在这里判断 UTC，避免不同节点在仓库发布前更新。
    TODAY=$(date -u +%F)
    [ "$(date -u +%H)" -ge 10 ] || exit 0
    [ "$(cat "${STATE_DIR}/success" 2>/dev/null)" != "$TODAY" ] || exit 0
    NOW=$(date -u +%s)
    LAST_ATTEMPT=$(cat "${STATE_DIR}/attempt" 2>/dev/null)
    # 比较小时而非相隔秒数，避免调度抖动让下一次重试多等一小时。
    if [[ "$LAST_ATTEMPT" =~ ^[0-9]+$ ]] &&
       [ "$((NOW / 3600))" -eq "$((LAST_ATTEMPT / 3600))" ]; then
        exit 0
    fi
    printf '%s\n' "$NOW" > "${STATE_DIR}/attempt" || exit 1
fi

UPDATE_TMP=$(mktemp -d /tmp/ip_sentinel_update.XXXXXX) || exit 1
trap 'rm -rf "$UPDATE_TMP"' EXIT HUP INT QUIT TERM

log() {
    local local_ver="${AGENT_VERSION:-未知}"
    
    mkdir -p "${INSTALL_DIR}/logs"

    local core_msg=$(printf "[v%-5s] [%-5s] [%-7s] [%s] %s" "$local_ver" "$2" "$1" "$REGION_CODE" "$3")
    # 节点分布在不同时区，日志统一用 UTC 便于按时间排查。
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $core_msg" >> "$LOG_FILE"
    echo "$core_msg"
}

log "Updater" "INFO " "开始同步热数据"

if [[ "${IP_PREF:-4}" != "4" && "${IP_PREF:-4}" != "6" ]]; then
    IP_PREF="4"
fi
CURL_ARGS=("-${IP_PREF:-4}" -fsSL --connect-timeout 5 --max-time 30)

if [ -n "$BIND_IP" ]; then
    RAW_BIND_IP=$(echo "$BIND_IP" | tr -d '[]')
    if ! ip addr show 2>/dev/null | grep -qw "$RAW_BIND_IP"; then
        log "Updater" "WARN " "检测到绑定的出口 IP ($RAW_BIND_IP) 已丢失，自动退回默认路由！"
    else
        CURL_ARGS+=(--interface "$RAW_BIND_IP")
    fi
fi

download_file() {
    local source_url="$1"
    local destination_file="$2"

    "$CURL_BIN" "${CURL_ARGS[@]}" "$source_url" -o "$destination_file"
}

if [ "${1:-}" = "--scheduled" ]; then
    # Actions 可能延迟，过了约定时刻也不能把昨天的数据记作今天同步成功。
    if ! download_file "${REPO_RAW_URL}/data/keywords/updated_at" "${UPDATE_TMP}/updated_at" ||
       [ "$(cat "${UPDATE_TMP}/updated_at" 2>/dev/null)" != "$TODAY" ]; then
        log "Updater" "WARN " "仓库尚未发布 ${TODAY} 的数据，或发布日期读取失败，稍后重试"
        exit 1
    fi
fi

UPDATE_FAILED=0

is_valid_keyword_file() {
    local keyword_file="$1"
    local keyword_count

    [ -s "$keyword_file" ] || return 1
    grep -Iq . "$keyword_file" || return 1
    grep -Eiq '<!doctype|<html|404: not found' "$keyword_file" && return 1
    keyword_count=$(grep -cve '^[[:space:]]*$' "$keyword_file")
    [ "$keyword_count" -ge 5 ]
}

is_valid_region_file() {
    python3 - "$1" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as file:
        data = json.load(file)
except (OSError, ValueError):
    raise SystemExit(1)

required = ("region_name", "google_module", "trust_module")
if not all(data.get(key) for key in required):
    raise SystemExit(1)
PY
}

NOW=$(date +%s)
LAST_UPDATE=0

if [ -f "$UA_TIME_FILE" ]; then
    LAST_UPDATE=$(cat "$UA_TIME_FILE" | tr -d '\r\n')
fi

if ! [[ "$LAST_UPDATE" =~ ^[0-9]+$ ]]; then
    LAST_UPDATE=0
fi

DIFF=$((NOW - LAST_UPDATE))

if [ "$DIFF" -ge 2592000 ] || [ "$LAST_UPDATE" -eq 0 ]; then
    TMP_UA="${UPDATE_TMP}/user_agents.txt"
    if download_file "${REPO_RAW_URL}/data/user_agents.txt" "$TMP_UA" && [ -s "$TMP_UA" ]; then
        mv "$TMP_UA" "${INSTALL_DIR}/data/user_agents.txt"
        echo "$NOW" > "$UA_TIME_FILE"
        log "Updater" "INFO " "✅ 设备指纹池 (User-Agents) 30天错峰滚动更新成功"
    else
        log "Updater" "WARN " "❌ UA 池拉取失败，保留本地旧数据防崩溃"
        rm -f "$TMP_UA"
    fi
else
    DAYS_LEFT=$(((2592000 - DIFF) / 86400))
    log "Updater" "INFO " "⏳ 设备指纹池处于 30 天静默期 (剩余约 ${DAYS_LEFT} 天)，跳过拉取"
fi

TMP_KW="${UPDATE_TMP}/keywords.txt"

if download_file "${REPO_RAW_URL}/data/keywords/kw_${REGION_CODE}.txt" "$TMP_KW" &&
   is_valid_keyword_file "$TMP_KW" &&
   mv "$TMP_KW" "${INSTALL_DIR}/data/keywords/kw_${REGION_CODE}.txt"; then
    log "Updater" "INFO " "✅ 区域搜索词库 (kw_${REGION_CODE}) 每日同步成功"
else
    log "Updater" "WARN " "❌ 搜索词库拉取失败，保留本地旧数据防崩溃"
    UPDATE_FAILED=1
    rm -f "$TMP_KW"
fi

REGION_JSON_FILE=$(find "${INSTALL_DIR}/data/regions" -name "*.json" 2>/dev/null | head -n 1)

if [ -n "$REGION_JSON_FILE" ] && [ -f "$REGION_JSON_FILE" ]; then
    REL_PATH=${REGION_JSON_FILE#*${INSTALL_DIR}/}
    TMP_JSON="${UPDATE_TMP}/region.json"

    if download_file "${REPO_RAW_URL}/${REL_PATH}" "$TMP_JSON" &&
       is_valid_region_file "$TMP_JSON" && mv "$TMP_JSON" "$REGION_JSON_FILE"; then
        log "Updater" "INFO " "✅ 核心战区规则库 ($REL_PATH) 每日同步成功"
    else
        log "Updater" "WARN " "❌ 战区规则库拉取失败，保留本地旧数据"
        UPDATE_FAILED=1
        rm -f "$TMP_JSON"
    fi
fi

TMP_PROBE="${UPDATE_TMP}/ip_probe.sh"

# 校验下载文件的有效性，防止拉取不完整或劫持网页覆盖本地探针
if download_file "https://raw.githubusercontent.com/xykt/IPQuality/main/ip.sh" "$TMP_PROBE" && \
   [ -s "$TMP_PROBE" ] && grep -q "xykt" "$TMP_PROBE" 2>/dev/null; then
    mv "$TMP_PROBE" "${INSTALL_DIR}/core/ip_probe.sh"
    chmod +x "${INSTALL_DIR}/core/ip_probe.sh"
    log "Updater" "INFO " "✅ 深海声呐底层探针 (ip_probe.sh) 源文件安全对齐"
else
    log "Updater" "WARN " "❌ 探针源文件拉取受损或遭投毒劫持，已触发防砖机制，保留本地旧版本"
    rm -f "$TMP_PROBE" 2>/dev/null
fi

if [ -f "$LOG_FILE" ]; then
    tail -n 2000 "$LOG_FILE" > "${LOG_FILE}.tmp"
    mv "${LOG_FILE}.tmp" "$LOG_FILE"
    log "Updater" "INFO " "🧹 系统日志已完成定期清理瘦身 (保留最新 2000 行)"
fi

log "Updater" "INFO " "热数据同步与日志维护结束"
if [ "${1:-}" = "--scheduled" ] && [ "$UPDATE_FAILED" -eq 0 ]; then
    printf '%s\n' "$TODAY" > "${STATE_DIR}/success" || exit 1
fi
exit "$UPDATE_FAILED"
