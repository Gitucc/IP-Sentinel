#!/bin/bash

source /opt/ip_sentinel/config.conf

DYNAMIC_IP_PREF="${IP_PREF:-4}"
PROBE_ARGS=("-y" "-j" "-f") # 默认注入: 自动确认、JSON格式、明文无掩码IP

if [[ -n "$BIND_IP" && "$BIND_IP" =~ ^[0-9a-fA-F:\[\]\.]+$ ]]; then
    RAW_BIND_IP=$(echo "$BIND_IP" | tr -d '[]')
    # 探测网卡存活状态，防止 IP 漂移导致报错
    if ip addr show 2>/dev/null | grep -qw "$RAW_BIND_IP"; then
                PROBE_ARGS+=("-i" "$RAW_BIND_IP")
        
                if [[ "$RAW_BIND_IP" == *":"* ]]; then
            DYNAMIC_IP_PREF="6"
        elif [[ "$RAW_BIND_IP" == *"."* ]]; then
            DYNAMIC_IP_PREF="4"
        fi
    fi
fi

PROBE_ARGS+=("-${DYNAMIC_IP_PREF}")

PROBE_SCRIPT="/opt/ip_sentinel/core/ip_probe.sh"

if [ -f "$PROBE_SCRIPT" ] && ! grep -q "xykt" "$PROBE_SCRIPT" 2>/dev/null; then
    rm -f "$PROBE_SCRIPT"
fi

if [ ! -s "$PROBE_SCRIPT" ]; then
        curl -sL -m 10 "https://raw.githubusercontent.com/xykt/IPQuality/main/ip.sh" -o "$PROBE_SCRIPT" 2>/dev/null
    
        if ! grep -q "xykt" "$PROBE_SCRIPT" 2>/dev/null; then
        rm -f "$PROBE_SCRIPT" 2>/dev/null
        curl -sL -m 15 "https://IP.Check.Place" -o "$PROBE_SCRIPT" 2>/dev/null
    fi
    chmod +x "$PROBE_SCRIPT" 2>/dev/null
fi

preflight_check() {
    local curl_args=("-s" "-m" "4")
        for ((i=1; i<=$#; i++)); do
        if [[ "${!i}" == "-i" ]]; then
            local next=$((i+1))
            curl_args+=("--interface" "${!next}")
        elif [[ "${!i}" == "-4" ]]; then
            curl_args+=("-4")
        elif [[ "${!i}" == "-6" ]]; then
            curl_args+=("-6")
        fi
    done
        curl "${curl_args[@]}" "https://www.cloudflare.com/cdn-cgi/trace" >/dev/null 2>&1
    return $?
}

FINAL_ARGS=()
if preflight_check "${PROBE_ARGS[@]}"; then
        FINAL_ARGS=("${PROBE_ARGS[@]}")
else
        FALLBACK_ARGS=("-y" "-j" "-${DYNAMIC_IP_PREF}")
    if preflight_check "${FALLBACK_ARGS[@]}"; then
        FINAL_ARGS=("${FALLBACK_ARGS[@]}")
    else
                FINAL_ARGS=("-y" "-j")
    fi
fi

RAW_OUTPUT=$(timeout 300 bash "$PROBE_SCRIPT" "${FINAL_ARGS[@]}" 2>/dev/null)
JSON_DATA="{${RAW_OUTPUT#*\{}"
ESC=$(printf '\033')
JSON_DATA=$(printf "%s" "$JSON_DATA" | sed -e "s/${ESC}\[[0-9;]*[a-zA-Z]//g" -e "s/${ESC}[0-9;]*[a-zA-Z]//g" -e "s/x1b\\[[0-9;]*[a-zA-Z]//g" -e "s/x1b[0-9;]*[a-zA-Z]//g")
IP_ADDR=$(echo "$JSON_DATA" | jq -r '.Head.IP // empty' 2>/dev/null)

if [ -z "$IP_ADDR" ]; then
    curl -s -X POST "${TG_API_URL}" \
        -d "chat_id=${CHAT_ID}" \
        -d "parse_mode=Markdown" \
        -d "text=❌ *深海声呐探测失败*
📍 节点：\`${NODE_ALIAS}\`
🌐 锁定IP：\`${PUBLIC_IP}\`
⚠️ *未收到有效回波。检测源超时或数据解析受阻。*" >/dev/null
    exit 1
fi

ASN=$(echo "$JSON_DATA" | jq -r '.Info.ASN // "Unknown"' 2>/dev/null)
ORG=$(echo "$JSON_DATA" | jq -r '.Info.Organization // "Unknown"' 2>/dev/null)
CITY=$(echo "$JSON_DATA" | jq -r '.Info.City.Name // "Unknown"' 2>/dev/null)
COUNTRY=$(echo "$JSON_DATA" | jq -r '.Info.Region.Name // "Unknown"' 2>/dev/null)
IP_TYPE=$(echo "$JSON_DATA" | jq -r '.Info.Type // "未知属性"' 2>/dev/null)
USAGE_TYPE=$(echo "$JSON_DATA" | jq -r '.Type.Usage.IPinfo // "未知场景"' 2>/dev/null)

SCAM_SCORE=$(echo "$JSON_DATA" | jq -r '.Score.SCAMALYTICS // "0"' 2>/dev/null)
ABUSE_SCORE=$(echo "$JSON_DATA" | jq -r '.Score.AbuseIPDB // "0"' 2>/dev/null)
IPQS_SCORE=$(echo "$JSON_DATA" | jq -r '.Score.IPQS // "0"' 2>/dev/null)
IP2L_SCORE=$(echo "$JSON_DATA" | jq -r '.Score.IP2LOCATION // "0"' 2>/dev/null)
FRAUD_RISK=$(echo "$JSON_DATA" | jq -r '.Score.ipapi // "0%"' 2>/dev/null)

# 过滤 API 阻断带来的空值
[ "$SCAM_SCORE" == "null" ] || [ -z "$SCAM_SCORE" ] && SCAM_SCORE="N/A"
[ "$ABUSE_SCORE" == "null" ] || [ -z "$ABUSE_SCORE" ] && ABUSE_SCORE="N/A"
[ "$IPQS_SCORE" == "null" ] || [ -z "$IPQS_SCORE" ] && IPQS_SCORE="N/A"
[ "$IP2L_SCORE" == "null" ] || [ -z "$IP2L_SCORE" ] && IP2L_SCORE="N/A"
[ "$FRAUD_RISK" == "null" ] || [ -z "$FRAUD_RISK" ] && FRAUD_RISK="N/A"

IS_PROXY="🟢 干净"
if echo "$JSON_DATA" | jq -e '.Factor.Proxy | to_entries | any(.value == true)' >/dev/null 2>&1 || \
   echo "$JSON_DATA" | jq -e '.Factor.VPN | to_entries | any(.value == true)' >/dev/null 2>&1; then
    IS_PROXY="🟡 疑似代理/VPN"
fi

parse_media() {
    local status=$(echo "$JSON_DATA" | jq -r ".Media.$1.Status // \"未知\"" 2>/dev/null)
    local reg=$(echo "$JSON_DATA" | jq -r ".Media.$1.Region // \"\"" 2>/dev/null)
    local type=$(echo "$JSON_DATA" | jq -r ".Media.$1.Type // \"\"" 2>/dev/null)
    
    if [[ "$status" == *"解锁"* ]]; then
        echo "🟢 ${reg} (${type})"
    elif [[ "$status" == *"仅"* ]] || [[ "$status" == *"机房"* ]] || [[ "$status" == *"待支持"* ]]; then
                echo "🟡 ${status} ${reg}"
    elif [[ "$status" == *"屏蔽"* ]] || [[ "$status" == *"失败"* ]] || [[ "$status" == *"中国"* ]] || [[ "$status" == *"禁"* ]]; then
                echo "🔴 ${status}"
    else
        echo "⚪ ${status}"
    fi
}

NF_STAT=$(parse_media "Netflix")
YT_STAT=$(parse_media "Youtube")
DP_STAT=$(parse_media "DisneyPlus")
TK_STAT=$(parse_media "TikTok")
GPT_STAT=$(parse_media "ChatGPT")
APV_STAT=$(parse_media "AmazonPrimeVideo")

RAW_NF_STAT=$(echo "$JSON_DATA" | jq -r '.Media.Netflix.Status // "Unknown"' 2>/dev/null)
RAW_YT_REG=$(echo "$JSON_DATA" | jq -r '.Media.Youtube.Region // ""' 2>/dev/null)
RAW_YT_STAT=$(echo "$JSON_DATA" | jq -r '.Media.Youtube.Status // "Unknown"' 2>/dev/null)

PORT25=$(echo "$JSON_DATA" | jq -r '.Mail.Port25 // "false"' 2>/dev/null)
[ "$PORT25" == "true" ] && P25_TEXT="✅ 畅通" || P25_TEXT="❌ 封堵"
DNS_BLACK=$(echo "$JSON_DATA" | jq -r '.Mail.DNSBlacklist.Blacklisted // "0"' 2>/dev/null)
DNS_MARK=$(echo "$JSON_DATA" | jq -r '.Mail.DNSBlacklist.Marked // "0"' 2>/dev/null)

WARNING_MSG=""
if [[ "$RAW_YT_REG" == "CN" ]] || [[ "$RAW_YT_STAT" == *"中国"* ]]; then
        WARNING_MSG=$'\n🚨 **[高危] 该节点已被 Google 判定为中国大陆 (送中)！**\n'
fi

LOCAL_VER="${AGENT_VERSION:-未知}"
CURRENT_TIME=$(date -u "+%Y-%m-%d %H:%M:%S UTC")

LINK_IP=$(echo "$PUBLIC_IP" | tr -d '[]')

REPORT="🎯 *IP-Sentinel 深海声呐报告*
📍 节点：\`${NODE_ALIAS}\`
🌐 地址：\`${IP_ADDR}\`${WARNING_MSG}

*🏢 物理身份与网络属性*
\`AS${ASN}\` | \`${ORG}\`
**定位:** \`${COUNTRY} - ${CITY}\`
**属性:** \`${IP_TYPE}\` | \`${USAGE_TYPE}\`
**探针:** ${IS_PROXY}

*🛡️ 欺诈雷达 (0为最优)*
• **Scamalytics:** \`${SCAM_SCORE}/100\`
• **AbuseIPDB:** \`${ABUSE_SCORE}/100\`
• **IPQS:** \`${IPQS_SCORE}/100\`
• **IP2Location:** \`${IP2L_SCORE}/100\`
• **IPAPI 风险率:** \`${FRAUD_RISK}\`

*🎬 核心业务解锁*
• **YouTube:** ${YT_STAT}
• **Netflix:** ${NF_STAT}
• **Disney+:** ${DP_STAT}
• **PrimeVideo:** ${APV_STAT}
• **TikTok:** ${TK_STAT}
• **ChatGPT:** ${GPT_STAT}

*✉️ 邮局与污染度*
• **25 端口出站:** ${P25_TEXT}
• **DNS 污染库:** 严重 \`${DNS_BLACK}\` | 轻微 \`${DNS_MARK}\`

_👉 [🔍 详细信用图谱直达 (Scamalytics)](https://scamalytics.com/ip/${LINK_IP})_

⏱️ \`${CURRENT_TIME}\` | ⚙️ \`v${LOCAL_VER}\`"

SAFE_SCAM_SCORE=$(echo "$SCAM_SCORE" | tr -cd '0-9')
[ -z "$SAFE_SCAM_SCORE" ] && SAFE_SCAM_SCORE="0"

RAW_GOOG_STAT="${RAW_YT_REG:-$RAW_YT_STAT}"
[ -z "$RAW_GOOG_STAT" ] && RAW_GOOG_STAT="未知"
RAW_GPT_STAT=$(echo "$JSON_DATA" | jq -r '.Media.ChatGPT.Status // "未知"' 2>/dev/null)

S_GOOG=$(echo "$RAW_GOOG_STAT" | tr -d '\n\r ')
S_NF=$(echo "$RAW_NF_STAT" | tr -d '\n\r ')
S_GPT=$(echo "$RAW_GPT_STAT" | tr -d '\n\r ')
CB_DATA="svq|${NODE_NAME}|${SAFE_SCAM_SCORE}|${S_GOOG}|${S_NF}|${S_GPT}"

JSON_PAYLOAD=$(jq -n \
  --arg cid "$CHAT_ID" \
  --arg txt "$REPORT" \
  --arg cb "$CB_DATA" \
  --arg cb_manage "manage:${NODE_NAME}" \
  '{
    chat_id: $cid,
    text: $txt,
    parse_mode: "Markdown",
    disable_web_page_preview: true,
    reply_markup: {
      inline_keyboard: [
        [{text: "📥 将本次体检录入趋势库", callback_data: $cb}],
        [{text: "⚙️ 调出该节点控制台", callback_data: $cb_manage}]
      ]
    }
  }')

curl -s -X POST "${TG_API_URL}" -H "Content-Type: application/json" -d "$JSON_PAYLOAD" >/dev/null