#!/bin/bash


INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
LOG_FILE="${INSTALL_DIR}/logs/sentinel.log"

if [ ! -f "$CONFIG_FILE" ]; then exit 1; fi
source "$CONFIG_FILE"

if [ -z "$TG_TOKEN" ] || [ -z "$CHAT_ID" ]; then
    echo "⚠️ 未配置 Telegram 机器人参数，取消播报。"
    exit 0
fi

LOCK_FILE="${INSTALL_DIR}/core/.report_lock"
if [ -f "$LOCK_FILE" ]; then
    LAST_RUN=$(cat "$LOCK_FILE" 2>/dev/null)
    NOW=$(date +%s)
    if [[ "$LAST_RUN" =~ ^[0-9]+$ ]]; then
        if [ $((NOW - LAST_RUN)) -lt 60 ]; then
            echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] [v${AGENT_VERSION:-未知}] [WARN ] [Report ] [SYSTEM] ⚠️ 战报请求过于频繁，触发 60 秒防并发请求限流拦截。" >> "${INSTALL_DIR}/logs/sentinel.log"
            exit 0
        fi
    fi
fi
echo $(date +%s) > "$LOCK_FILE"

if [ -z "$NODE_NAME" ]; then
    IP_HASH=$(echo "${PUBLIC_IP:-127.0.0.1}" | md5sum | cut -c 1-4 | tr 'a-z' 'A-Z')
    NODE_NAME="$(hostname | cut -c 1-10)-${IP_HASH}"
fi
NODE_ALIAS="${NODE_ALIAS:-$NODE_NAME}"

CURL_BIND_OPT=""
DYNAMIC_IP_PREF="-${IP_PREF:-4}"

if [[ -n "$BIND_IP" && "$BIND_IP" =~ ^[0-9a-fA-F:\.]+$ ]]; then
    RAW_BIND_IP=$(echo "$BIND_IP" | tr -d '[]')
    if ! ip addr show 2>/dev/null | grep -qw "$RAW_BIND_IP"; then
        CURL_BIND_OPT=""
    else
        CURL_BIND_OPT="--interface $BIND_IP"
        if [[ "$BIND_IP" == *":"* ]]; then
            DYNAMIC_IP_PREF="-6"
        elif [[ "$BIND_IP" == *"."* ]]; then
            DYNAMIC_IP_PREF="-4"
        fi
    fi
fi

CURRENT_IP=$( (curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 api.ip.sb/ip || curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 ifconfig.me) 2>/dev/null | tr -d '[:space:]' )
[ -z "$CURRENT_IP" ] && CURRENT_IP="${PUBLIC_IP:-$BIND_IP}"

# 为 IPv6 环境添加方括号
[[ "$CURRENT_IP" == *":"* ]] && [[ "$CURRENT_IP" != *"["* ]] && CURRENT_IP="[${CURRENT_IP}]"

ISP_INFO=""

ISP_INFO=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 ipinfo.io/org 2>/dev/null)

if [ -z "$ISP_INFO" ] || [[ "$ISP_INFO" == *"error"* ]]; then
    ISP_INFO=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 ip-api.com/line/?fields=isp 2>/dev/null)
fi

if [ -z "$ISP_INFO" ] || [[ "$ISP_INFO" == *"error"* ]]; then
    if command -v jq &> /dev/null; then
        ISP_INFO=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 api.ip.sb/geoip | jq -r '.organization' 2>/dev/null)
    fi
fi

ISP_INFO=$(echo "$ISP_INFO" | sed -E 's/^AS[0-9]+ //')
[ -z "$ISP_INFO" ] || [ "$ISP_INFO" == "null" ] && ISP_INFO="未知 ISP"

if [[ "$ISP_INFO" == *"Cloudflare"* ]]; then
    IP_TYPE="Cloudflare Warp 🛰️"
else
    IP_TYPE="$ISP_INFO 🏠"
fi

BASE_CC="${REGION_CODE%%-*}"
case "$BASE_CC" in
    US) FLAG="🇺🇸" ;; JP) FLAG="🇯🇵" ;; HK) FLAG="🇭🇰" ;; TW) FLAG="🇹🇼" ;; SG) FLAG="🇸🇬" ;;
    UK|GB) FLAG="🇬🇧" ;; DE) FLAG="🇩🇪" ;; FR) FLAG="🇫🇷" ;; NL) FLAG="🇳🇱" ;; CA) FLAG="🇨🇦" ;;
    AU) FLAG="🇦🇺" ;; KR) FLAG="🇰🇷" ;; IN) FLAG="🇮🇳" ;; BR) FLAG="🇧🇷" ;; RU) FLAG="🇷🇺" ;;
    CH) FLAG="🇨🇭" ;; SE) FLAG="🇸🇪" ;; NO) FLAG="🇳🇴" ;; DK) FLAG="🇩🇰" ;; FI) FLAG="🇫🇮" ;;
    IT) FLAG="🇮🇹" ;; ES) FLAG="🇪🇸" ;; PT) FLAG="🇵🇹" ;; IE) FLAG="🇮🇪" ;; PL) FLAG="🇵🇱" ;;
    AT) FLAG="🇦🇹" ;; BE) FLAG="🇧🇪" ;; TR) FLAG="🇹🇷" ;; ZA) FLAG="🇿🇦" ;; AE) FLAG="🇦🇪" ;;
    MY) FLAG="🇲🇾" ;; ID) FLAG="🇮🇩" ;; VN) FLAG="🇻🇳" ;; TH) FLAG="🇹🇭" ;; PH) FLAG="🇵🇭" ;;
    NZ) FLAG="🇳🇿" ;; AR) FLAG="🇦🇷" ;; CL) FLAG="🇨🇱" ;; MX) FLAG="🇲🇽" ;; IL) FLAG="🇮🇱" ;;
    SA) FLAG="🇸🇦" ;; EG) FLAG="🇪🇬" ;; NG) FLAG="🇳🇬" ;; KE) FLAG="🇰🇪" ;; RO) FLAG="🇷🇴" ;;
    BG) FLAG="🇧🇬" ;; CZ) FLAG="🇨🇿" ;; HU) FLAG="🇭🇺" ;; GR) FLAG="🇬🇷" ;; UA) FLAG="🇺🇦" ;;
    MO) FLAG="🇲🇴" ;; KH) FLAG="🇰🇭" ;; MM) FLAG="🇲🇲" ;; LA) FLAG="🇱🇦" ;;
    MN) FLAG="🇲🇳" ;; NP) FLAG="🇳🇵" ;; BD) FLAG="🇧🇩" ;;
    *) FLAG="🌐" ;;
esac

LOG_CONTENT=$(tail -n 1000 "$LOG_FILE" 2>/dev/null)

# 检查文件锁以判定后台任务是否运行
IS_RUNNING="false"
if ! flock -n /tmp/ip_sentinel_runner.lock true 2>/dev/null; then
    IS_RUNNING="true"
fi

if [ -z "$LOG_CONTENT" ]; then
    run_tip=""
    if [ "$IS_RUNNING" == "true" ]; then
        run_tip="%0A⏳ *状态: 维护任务正在后台执行中，最新数据将在本轮结束后载入，请稍候...*"
    else
        run_tip="%0A⏳ *提示: 战报数据会在每次巡逻/维护任务完成后自动更新。*"
    fi
    read -r -d '' MSG <<EOT
🛑 **[IP-Sentinel] 告警：节点异常**
----------------------------
📍 **节点名称**: \`${NODE_ALIAS}\`
⚠️ **警告**: 过去 24 小时无运行日志！
🛠️ **建议**: 节点可能刚部署完毕，请在面板手动执行一次养护动作。${run_tip}
EOT
else
    LAST_LOG_LINE=$(echo "$LOG_CONTENT" | grep "\[SCORE\]" | tail -n 1)
    LAST_TIME=$(echo "$LAST_LOG_LINE" | awk '{print $1,$2}' | tr -d '[]')
    LAST_MOD=$(echo "$LAST_LOG_LINE" | awk '{print $4}' | tr -d '[]')
    LAST_SCORE=$(echo "$LAST_LOG_LINE" | awk -F'自检结论: ' '{print $2}')

    MSG="📊 **IP-Sentinel 每日简报 (${FLAG} ${REGION_NAME})**
----------------------------
📍 **节点名称**: \`${NODE_ALIAS}\`
📡 **出口 IP**: \`${CURRENT_IP}\`
🛡️ **IP 属性**: ${IP_TYPE}"

    if [ "$ENABLE_GOOGLE" == "true" ]; then
        GOOGLE_LOGS=$(echo "$LOG_CONTENT" | grep "\[Google")
        G_TOTAL=$(echo "$GOOGLE_LOGS" | grep "\[START\]" -c)
        G_SUCCESS=$(echo "$GOOGLE_LOGS" | grep "✅" -c)
        G_FAILED=$(echo "$GOOGLE_LOGS" | grep "❌" -c)
        G_WARN=$(echo "$GOOGLE_LOGS" | grep "⚠️" -c)
        
        G_RATE="0.0"
        [ "$G_TOTAL" -gt 0 ] && G_RATE=$(awk "BEGIN {printf \"%.1f\", ($G_SUCCESS/$G_TOTAL)*100}")

        MSG="$MSG

🎯 **[Google 区域纠偏]**
🚀 执行总数: ${G_TOTAL} 次 (胜率: **${G_RATE}%**)
✅ 成功: ${G_SUCCESS} | ❌ 送中: ${G_FAILED} | ⚠️ 警告: ${G_WARN}"
    fi

    if [ "$ENABLE_TRUST" == "true" ]; then
        TRUST_LOGS=$(echo "$LOG_CONTENT" | grep "\[Trust")
        T_TOTAL=$(echo "$TRUST_LOGS" | grep "\[START\]" -c)
        T_SUCCESS=$(echo "$TRUST_LOGS" | grep "✅" -c)
        T_FAILED=$(echo "$TRUST_LOGS" | grep "❌" -c)
        
        T_RATE="0.0"
        [ "$T_TOTAL" -gt 0 ] && T_RATE=$(awk "BEGIN {printf \"%.1f\", ($T_SUCCESS/$T_TOTAL)*100}")

        MSG="$MSG

🔰 **[IP 信用净化]**
🚀 净化总数: ${T_TOTAL} 轮 (成功率: **${T_RATE}%**)
✅ 成功注入: ${T_SUCCESS} | ❌ 访问受阻: ${T_FAILED}"
    fi

    MSG="$MSG

🕒 **最近执行快照:  \`${LAST_MOD:-"System"} \`**
时间: ${LAST_TIME:-"暂无数据"} (节点本地)
结论: ${LAST_SCORE:-"暂无数据"}"

    if [ "$IS_RUNNING" == "true" ]; then
        MSG="$MSG

⏳ **状态**: 维护任务正在后台执行中，最新数据将在本轮结束后自动更新。"
    else
        MSG="$MSG

⏳ **更新机制**: 战报数据会在每次巡逻/维护任务完成后自动更新。"
    fi

fi

LOCAL_VER="${AGENT_VERSION:-未知}"
# 使用 UTC 时间消除多节点时区偏差
REPORT_UTC_TIME=$(date -u "+%Y-%m-%d %H:%M:%S UTC")

REPO_RAW_URL="https://raw.githubusercontent.com/Gitucc/IP-Sentinel/main"
REMOTE_VER=$(curl -s -m 3 "${REPO_RAW_URL}/version.txt" | grep "^AGENT_VERSION=" | cut -d'=' -f2 | tr -d '[:space:]')

MSG="$MSG
----------------------------
🛡️ **系统引擎状态**
⏱️ 战报生成: \`${REPORT_UTC_TIME}\`"

if [ -n "$REMOTE_VER" ]; then
    if [ "$REMOTE_VER" != "$LOCAL_VER" ]; then
        MSG="$MSG
当前运行版本: \`v${LOCAL_VER}\`
✨ **发现新版本**: \`v${REMOTE_VER}\` (建议更新)
💡 *系统提示：检测到新版引擎，建议通过控制中枢执行 OTA 升级！*"
    else
        MSG="$MSG
当前运行版本: \`v${LOCAL_VER}\` (✅已是最新)
💡 *IP-Sentinel 持续为您守护节点。*
*若本项目对您有帮助，欢迎前往 GitHub 赐予 🌟*"
    fi
else
    MSG="$MSG
当前运行版本: \`v${LOCAL_VER}\`
💡 *IP-Sentinel 持续为您守护节点。*
*若本项目对您有帮助，欢迎前往 GitHub 赐予 🌟*"
fi

JSON_PAYLOAD=$(jq -n \
  --arg cid "$CHAT_ID" \
  --arg txt "$MSG" \
  --arg cb "manage:${NODE_NAME}" \
  '{
    chat_id: $cid,
    text: $txt,
    parse_mode: "Markdown",
    disable_web_page_preview: true,
    reply_markup: {
      inline_keyboard: [[{"text": "⚙️ 调出该节点控制台", "callback_data": $cb}]]
    }
  }')

RESPONSE=$(curl -s -m 10 -X POST "${TG_API_URL}" \
    -H "Content-Type: application/json" \
    -d "$JSON_PAYLOAD")

if [[ "$RESPONSE" != *"\"ok\":true"* ]]; then
    echo "❌ 战报发送失败！API 响应: $RESPONSE" >> "${INSTALL_DIR}/logs/error.log"
else
    echo "✅ 战报推送成功！"
fi