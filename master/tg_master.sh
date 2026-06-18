#!/bin/bash

CONF="/opt/ip_sentinel_master/master.conf"
[ ! -f "$CONF" ] && exit 1
source "$CONF"

REPO_RAW_URL="https://raw.githubusercontent.com/Gitucc/IP-Sentinel/main"
MASTER_VERSION=${MASTER_VERSION:-"3.5.0"}

OFFSET_FILE="${MASTER_DIR}/.tg_offset"
[[ -f $OFFSET_FILE ]] || echo "0" > $OFFSET_FILE

get_flag() {
    local region=$(echo "$1" | tr 'a-z' 'A-Z')
    local base_cc="${region%%-*}"
    local flag="🌐"
    case "$base_cc" in
        US) flag="🇺🇸" ;; JP) flag="🇯🇵" ;; HK) flag="🇭🇰" ;; TW) flag="🇹🇼" ;; SG) flag="🇸🇬" ;;
        UK|GB) flag="🇬🇧" ;; DE) flag="🇩🇪" ;; FR) flag="🇫🇷" ;; NL) flag="🇳🇱" ;; CA) flag="🇨🇦" ;;
        AU) flag="🇦🇺" ;; KR) flag="🇰🇷" ;; IN) flag="🇮🇳" ;; BR) flag="🇧🇷" ;; RU) flag="🇷🇺" ;;
        CH) flag="🇨🇭" ;; SE) flag="🇸🇪" ;; NO) flag="🇳🇴" ;; DK) flag="🇩🇰" ;; FI) flag="🇫🇮" ;;
        IT) flag="🇮🇹" ;; ES) flag="🇪🇸" ;; PT) flag="🇵🇹" ;; IE) flag="🇮🇪" ;; PL) flag="🇵🇱" ;;
        AT) flag="🇦🇹" ;; BE) flag="🇧🇪" ;; TR) flag="🇹🇷" ;; ZA) flag="🇿🇦" ;; AE) flag="🇦🇪" ;;
        MY) flag="🇲🇾" ;; ID) flag="🇮🇩" ;; VN) flag="🇻🇳" ;; TH) flag="🇹🇭" ;; PH) flag="🇵🇭" ;;
        NZ) flag="🇳🇿" ;; AR) flag="🇦🇷" ;; CL) flag="🇨🇱" ;; MX) flag="🇲🇽" ;; IL) flag="🇮🇱" ;;
        SA) flag="🇸🇦" ;; EG) flag="🇪🇬" ;; NG) flag="🇳🇬" ;; KE) flag="🇰🇪" ;; RO) flag="🇷🇴" ;;
        BG) flag="🇧🇬" ;; CZ) flag="🇨🇿" ;; HU) flag="🇭🇺" ;; GR) flag="🇬🇷" ;; UA) flag="🇺🇦" ;;
        MO) flag="🇲🇴" ;; KH) flag="🇰🇭" ;; MM) flag="🇲🇲" ;; LA) flag="🇱🇦" ;;
        MN) flag="🇲🇳" ;; NP) flag="🇳🇵" ;; BD) flag="🇧🇩" ;;
    esac
    echo "$flag"
}

send_ui() {
    curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"$1\",\"text\":\"$2\",\"parse_mode\":\"Markdown\",\"reply_markup\":{\"inline_keyboard\":$3}}" > /dev/null
}

send_msg() {
    curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=$1" -d "text=$2" -d "parse_mode=Markdown" > /dev/null
}

edit_msg() {
    curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/editMessageText" \
        -d "chat_id=$1" -d "message_id=$2" -d "text=$3" -d "parse_mode=Markdown" > /dev/null
}

edit_ui() {
    curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/editMessageText" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"$1\",\"message_id\":\"$2\",\"text\":\"$3\",\"parse_mode\":\"Markdown\",\"reply_markup\":{\"inline_keyboard\":$4}}" > /dev/null
}

log_master_event() {
    local level="$1"
    local category="$2"
    local message="$3"
    local log_line="[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] [$level] [$category] $message"
    echo "$log_line"
    local log_dir="/opt/ip_sentinel/logs"
    [ -d "$log_dir" ] || mkdir -p "$log_dir"
    echo "$log_line" >> "${log_dir}/master.log"
}

execute_sqlite_query() {
    printf ".timeout 5000\n%s\n" "$1" | sqlite3 "$DB_FILE"
}

generate_signed_url() {
    local target_ip=$1
    local target_port=$2
    local action_path=$3
    local query_params=$4
    local target_node=$5
    local current_time=$(date +%s)
    
    local signature_key="$CHAT_ID"
    if [ -n "$target_node" ]; then
        local retrieved_token=$(execute_sqlite_query "SELECT agent_token FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$target_node' LIMIT 1;")
        if [ -n "$retrieved_token" ] && [ "$retrieved_token" != "null" ]; then
            signature_key="$retrieved_token"
        fi
    fi

    local sorted_params=""
    if [ -n "$query_params" ]; then
        sorted_params=$(echo -n "$query_params" | tr '&' '\n' | sort | tr '\n' '&' | sed 's/&$//')
    fi
    
    local signature_payload
    local url_parameters
    if [ -n "$sorted_params" ]; then
        signature_payload="${action_path}:${sorted_params}:${current_time}"
        url_parameters="&${query_params}"
    else
        signature_payload="${action_path}:${current_time}"
        url_parameters=""
    fi
    
    local generated_signature=$(printf "%s" "$signature_payload" | openssl dgst -sha256 -mac HMAC -macopt key:"$signature_key" | awk '{print $NF}')
    
    echo "https://${target_ip}:${target_port}${action_path}?t=${current_time}${url_parameters}&sign=${generated_signature}"
}

dispatch_agent_request() {
    local destination_ips="$1"
    local agent_port="$2"
    local request_path="$3"
    local request_query="$4"
    local target_node="$5"
    local request_result="FAILED"
    
    local clean_ips=$(echo "$destination_ips" | tr '_' ',')
    IFS=',' read -r -a ip_array <<< "$clean_ips"
    for current_ip in "${ip_array[@]}"; do
        if [ -n "$current_ip" ]; then
            local request_url=$(generate_signed_url "$current_ip" "$agent_port" "$request_path" "$request_query" "$target_node")
            
            log_master_event "INFO" "Dispatcher" "Sending signed request: $request_url. Node: $target_node"
            request_result=$(curl -k -s --connect-timeout 4 -m 12 "$request_url" || echo "FAILED")
            log_master_event "INFO" "Dispatcher" "Response from $current_ip: $request_result"
            if [ "$request_result" != "FAILED" ] && [ -n "$request_result" ]; then
                echo "$request_result"
                return
            fi
        fi
    done
    echo "FAILED"
}

execute_sqlite_query "PRAGMA journal_mode=WAL;" > /dev/null 2>&1
execute_sqlite_query "PRAGMA synchronous=NORMAL;" > /dev/null 2>&1

# 自动探测并动态扩展节点表结构
execute_sqlite_query "ALTER TABLE nodes ADD COLUMN region TEXT DEFAULT 'UNKNOWN';" 2>/dev/null
execute_sqlite_query "ALTER TABLE nodes ADD COLUMN node_alias TEXT;" 2>/dev/null
execute_sqlite_query "ALTER TABLE nodes ADD COLUMN enable_google TEXT DEFAULT 'true';" 2>/dev/null
execute_sqlite_query "ALTER TABLE nodes ADD COLUMN enable_trust TEXT DEFAULT 'true';" 2>/dev/null
execute_sqlite_query "ALTER TABLE nodes ADD COLUMN enable_ota TEXT DEFAULT 'false';" 2>/dev/null
execute_sqlite_query "ALTER TABLE nodes ADD COLUMN agent_token TEXT;" 2>/dev/null

execute_sqlite_query "CREATE TABLE IF NOT EXISTS ip_trend_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    node_name TEXT,
    check_time DATETIME DEFAULT CURRENT_TIMESTAMP,
    scam_score INTEGER,
    nf_status TEXT
);" 2>/dev/null
execute_sqlite_query "ALTER TABLE ip_trend_log ADD COLUMN goog_status TEXT DEFAULT 'Unknown';" 2>/dev/null
execute_sqlite_query "ALTER TABLE ip_trend_log ADD COLUMN gpt_status TEXT DEFAULT 'Unknown';" 2>/dev/null

while true; do
    OFFSET=$(cat $OFFSET_FILE)
    UPDATES=$(curl -s --connect-timeout 5 -m 35 "https://api.telegram.org/bot${TG_TOKEN}/getUpdates?offset=${OFFSET}&timeout=30")
    
    COUNT=$(echo "$UPDATES" | jq -r '.result | length' 2>/dev/null)
    
    if [[ "$COUNT" =~ ^[0-9]+$ ]] && [ "$COUNT" -gt 0 ]; then
        echo "$UPDATES" | jq -c '.result[]' | while read -r UPDATE; do
            UPDATE_ID=$(echo "$UPDATE" | jq -r '.update_id')
            echo $((UPDATE_ID + 1)) > $OFFSET_FILE
            
            CHAT_ID=$(echo "$UPDATE" | jq -r '.message.chat.id // .callback_query.message.chat.id')
                CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
            
            callback_payload=$(echo "$UPDATE" | jq -r '.message.text // .callback_query.data')

            # 校验管理者 CHAT_ID
            if [[ -n "$ALLOWED_CHAT_ID" ]] && [[ "$CHAT_ID" != "$ALLOWED_CHAT_ID" ]]; then
                log_master_event "WARN" "Security" "Message rejected: Sender CHAT_ID '$CHAT_ID' is not ALLOWED_CHAT_ID '$ALLOWED_CHAT_ID'. Content: '$callback_payload'"
                continue
            fi
            
            log_master_event "INFO" "Receiver" "Received command from CHAT_ID '$CHAT_ID'. Payload: '$callback_payload'"

                callback_query_id=$(echo "$UPDATE" | jq -r '.callback_query.id // empty')
            callback_message_id=$(echo "$UPDATE" | jq -r '.callback_query.message.message_id // empty')

            if [[ "$callback_payload" == "svq|"* ]]; then
                IFS='|' read -r protocol_header RAW_NODE_ID RAW_SCORE RAW_GOOG_ST RAW_NF_ST RAW_GPT_ST <<< "$callback_payload"
                CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                
                # 正则清洗防范 SQL 注入
                NODE_ID=$(echo "$RAW_NODE_ID" | tr -cd 'a-zA-Z0-9_.-')
                SCORE=$(echo "$RAW_SCORE" | tr -cd '0-9')
                GOOG_ST=$(echo "$RAW_GOOG_ST" | tr -d '"'\''\`\$\|&;<>\n\r')
                NF_ST=$(echo "$RAW_NF_ST" | tr -d '"'\''\`\$\|&;<>\n\r')
                GPT_ST=$(echo "$RAW_GPT_ST" | tr -d '"'\''\`\$\|&;<>\n\r')

                if [ -n "$NODE_ID" ] && [ -n "$SCORE" ]; then
                    execute_sqlite_query "INSERT INTO ip_trend_log (node_name, scam_score, goog_status, nf_status, gpt_status) VALUES ('$NODE_ID', '$SCORE', '$GOOG_ST', '$NF_ST', '$GPT_ST');"
                    
                    if [ -n "$callback_query_id" ]; then
                        curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/answerCallbackQuery" \
                            -d "callback_query_id=${callback_query_id}" \
                            -d "text=✅ 报告已成功录入趋势库！" \
                            -d "show_alert=false" > /dev/null
                    fi

                                if [ -n "$callback_message_id" ]; then
                        curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/editMessageReplyMarkup" \
                            -H "Content-Type: application/json" \
                            -d "{\"chat_id\":\"${CHAT_ID}\",\"message_id\":\"${callback_message_id}\",\"reply_markup\":{\"inline_keyboard\":[[{\"text\":\"✅ 此报告已存档\",\"callback_data\":\"ignore\"}],[{\"text\":\"⚙️ 调出该节点控制台\",\"callback_data\":\"manage:${NODE_ID}\"}]]}}" > /dev/null
                    fi
                else
                    if [ -n "$callback_query_id" ]; then
                        curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/answerCallbackQuery" \
                            -d "callback_query_id=${callback_query_id}" \
                            -d "text=❌ 数据解析失败，入库中止。" \
                            -d "show_alert=true" > /dev/null
                    fi
                fi
                continue
            fi
            
            REPLY_TO_TEXT=$(echo "$UPDATE" | jq -r '.message.reply_to_message.text // empty')

            if [[ "$REPLY_TO_TEXT" == *"✏️ 请回复本消息以重命名节点:"* ]]; then
                TARGET_NODE=$(echo "$REPLY_TO_TEXT" | grep -v "✏️" | grep -v "仅限" | tr -d '\` ' | tr -cd 'a-zA-Z0-9_.-' | head -n 1)
                
                    NEW_ALIAS=$(echo "$callback_payload" | sed 's/_/-/g' | tr -d '"'\''\`\$\|&;<>\n\r:' | cut -c 1-30)
                
                if [ -n "$TARGET_NODE" ] && [ -n "$NEW_ALIAS" ]; then
                    callback_payload="do_rename:${TARGET_NODE}:${NEW_ALIAS}"
                fi
            fi
            
            if [[ "$callback_payload" == *"#REGISTER#"* ]]; then
                registration_record=$(echo "$callback_payload" | grep "#REGISTER#" | head -n 1 | tr -d '` ')
                
                    FIELD_COUNT=$(echo "$registration_record" | awk -F'|' '{print NF}')
                if [ "$FIELD_COUNT" -ge 8 ]; then
                    IFS='|' read -r protocol_header RAW_REGION RAW_NODE RAW_IP RAW_PORT RAW_ALIAS RAW_OTA RAW_TOKEN <<< "$registration_record"
                elif [ "$FIELD_COUNT" -eq 7 ]; then
                    IFS='|' read -r protocol_header RAW_REGION RAW_NODE RAW_IP RAW_PORT RAW_ALIAS RAW_OTA <<< "$registration_record"
                    RAW_TOKEN=""
                elif [ "$FIELD_COUNT" -eq 6 ]; then
                    IFS='|' read -r protocol_header RAW_REGION RAW_NODE RAW_IP RAW_PORT RAW_ALIAS <<< "$registration_record"
                    RAW_OTA="false"
                    RAW_TOKEN=""
                elif [ "$FIELD_COUNT" -eq 5 ]; then
                    IFS='|' read -r protocol_header RAW_REGION RAW_NODE RAW_IP RAW_PORT <<< "$registration_record"
                    RAW_ALIAS="$RAW_NODE"
                    RAW_OTA="false"
                    RAW_TOKEN=""
                else
                    IFS='|' read -r protocol_header RAW_NODE RAW_IP RAW_PORT <<< "$registration_record"
                    RAW_REGION="UNKNOWN"
                    RAW_ALIAS="$RAW_NODE"
                    RAW_OTA="false"
                    RAW_TOKEN=""
                fi
                
                CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                AGENT_REGION=$(echo "$RAW_REGION" | tr -cd 'a-zA-Z0-9' | cut -c 1-10)
                NODE_NAME=$(echo "$RAW_NODE" | tr -cd 'a-zA-Z0-9_.-' | cut -c 1-30)
                AGENT_IP=$(echo "$RAW_IP" | tr -cd 'a-zA-Z0-9.:\[\]-_,' | cut -c 1-150)
                AGENT_PORT=$(echo "$RAW_PORT" | tr -cd '0-9' | cut -c 1-5)
                NODE_ALIAS=$(echo "$RAW_ALIAS" | tr -d '"'\''\`\$\|&;<>\n\r' | cut -c 1-30)
                [ -z "$NODE_ALIAS" ] && NODE_ALIAS="$NODE_NAME"
                AGENT_OTA=$(echo "$RAW_OTA" | tr -cd 'a-z')
                [ -z "$AGENT_OTA" ] && AGENT_OTA="false"
                AGENT_TOKEN=$(echo "$RAW_TOKEN" | tr -cd 'a-fA-F0-9')
                
                # 限制非公网或回环地址以防御 SSRF
                if [[ "$AGENT_IP" =~ ^127\.|^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^::1$|^localhost$ ]]; then
                    send_msg "$CHAT_ID" "⛔ **安全过滤**：禁止注册私有或本地回环地址，以防御 SSRF 渗透。"
                    continue
                fi
                
                if [ -z "$NODE_NAME" ] || [ -z "$AGENT_IP" ] || [ -z "$AGENT_PORT" ] || [ -z "$CHAT_ID" ]; then
                    send_msg "$CHAT_ID" "⛔ **安全过滤**：注册数据包校验未通过，注册已拒绝。"
                    continue
                fi

                    execute_sqlite_query "INSERT INTO nodes (chat_id, node_name, agent_ip, agent_port, last_seen, region, node_alias, enable_ota, agent_token) VALUES ('$CHAT_ID', '$NODE_NAME', '$AGENT_IP', '$AGENT_PORT', CURRENT_TIMESTAMP, '$AGENT_REGION', '$NODE_ALIAS', '$AGENT_OTA', '$AGENT_TOKEN') ON CONFLICT(chat_id, node_name) DO UPDATE SET agent_ip='$AGENT_IP', agent_port='$AGENT_PORT', last_seen=CURRENT_TIMESTAMP, region='$AGENT_REGION', node_alias='$NODE_ALIAS', enable_ota='$AGENT_OTA', agent_token='$AGENT_TOKEN';"
                
                    FMT_AGENT_IP=$(echo "$AGENT_IP" | tr '_' ',')
                MAIN_SHOW_IP=$(echo "$FMT_AGENT_IP" | cut -d',' -f1)
                BACKUP_SHOW_IP=$(echo "$FMT_AGENT_IP" | cut -d',' -f2-)
                if [ -n "$BACKUP_SHOW_IP" ]; then
                    SHOW_MSG="✅ **中枢节点确认 (v${MASTER_VERSION})**%0A节点 \`${NODE_ALIAS}\` 档案已录入！%0A🌐 主通讯：\`${MAIN_SHOW_IP}\`%0A📡 容灾备用：\`${BACKUP_SHOW_IP}\`"
                else
                    SHOW_MSG="✅ **中枢节点确认 (v${MASTER_VERSION})**%0A节点 \`${NODE_ALIAS}\` 档案已录入！%0A🌐 通讯 IP：\`${MAIN_SHOW_IP}\`"
                fi
                send_msg "$CHAT_ID" "$SHOW_MSG"
                
                REGION_DATA=$(execute_sqlite_query "SELECT region, COUNT(*) FROM nodes WHERE chat_id='$CHAT_ID' GROUP BY region;")
                if [ -n "$REGION_DATA" ]; then
                    BTNS="["
                    while IFS='|' read -r REGION_NAME NODE_COUNT; do
                        [ -z "$REGION_NAME" ] && REGION_NAME="UNKNOWN"
                        FLAG=$(get_flag "$REGION_NAME")
                        BTNS="$BTNS[{\"text\":\"$FLAG $REGION_NAME ($NODE_COUNT 台)\",\"callback_data\":\"region:$REGION_NAME\"}],"
                    done <<< "$REGION_DATA"
                    BTNS="${BTNS%,}]"
                    send_ui "$CHAT_ID" "🌍 **全视界雷达面板**\n请选择要检阅的区域：" "$BTNS"
                fi
                continue
            fi

            case "$callback_payload" in
                "/start"|"/menu")
                    REMOTE_VER=$(curl -s -m 2 "${REPO_RAW_URL}/version.txt" | grep "^MASTER_VERSION=" | cut -d'=' -f2 | tr -d '[:space:]')
                    VER_INFO="当前版本: \`v${MASTER_VERSION}\`"
                    
                    BTN_MASTER_OTA=""
                    if [ -n "$REMOTE_VER" ]; then
                        if [ "$REMOTE_VER" != "$MASTER_VERSION" ]; then
                            VER_INFO="${VER_INFO}\n✨ **发现新版本**: \`v${REMOTE_VER}\` (可执行中枢热重载)"
                            if [ "$IS_OFFICIAL_GATEWAY" != "true" ] && [ "${ENABLE_MASTER_OTA:-false}" == "true" ]; then
                                BTN_MASTER_OTA="[{\"text\":\"🆙 升级控制中枢至 v${REMOTE_VER}\",\"callback_data\":\"master_ota_confirm\"}],"
                            fi
                        else
                            VER_INFO="当前版本: \`v${MASTER_VERSION}\` (✅已是最新)"
                        fi
                    fi

                    NODE_COUNT=$(execute_sqlite_query "SELECT COUNT(*) FROM nodes WHERE chat_id='$CHAT_ID';")

                    if [ "$IS_OFFICIAL_GATEWAY" != "true" ]; then
                        BTNS="[${BTN_MASTER_OTA}[{\"text\":\"🌍 进入全球雷达 (管理节点)\",\"callback_data\":\"list_nodes\"}], [{\"text\":\"🚀 唤醒全局巡逻\",\"callback_data\":\"all_run\"}, {\"text\":\"📊 获取全局简报\",\"callback_data\":\"all_reports\"}], [{\"text\":\"🔄 全网节点 OTA 热重载\",\"callback_data\":\"all_ota_confirm\"}], [{\"text\":\"🌟 前往 GitHub 点亮星标\",\"url\":\"https://github.com/Gitucc/IP-Sentinel\"}]]"
                    else
                        BTNS="[[{\"text\":\"🌍 进入全球雷达 (管理节点)\",\"callback_data\":\"list_nodes\"}], [{\"text\":\"🚀 唤醒全局巡逻\",\"callback_data\":\"all_run\"}, {\"text\":\"📊 获取全局简报\",\"callback_data\":\"all_reports\"}], [{\"text\":\"🌟 前往 GitHub 点亮星标\",\"url\":\"https://github.com/Gitucc/IP-Sentinel\"}]]"
                    fi
                    DISP_MASTER="${MASTER_NODE_NAME:-未命名中枢}"
                                TEXT_MSG="🛡️ **IP-Sentinel 控制中枢**\n${VER_INFO}\n中枢节点: \`${DISP_MASTER}\`\n\n📊 节点状态: 共有 \`${NODE_COUNT}\` 台节点在线\n欢迎回来，管理者。请下达系统指令："
                    send_ui "$CHAT_ID" "$TEXT_MSG" "$BTNS"
                    ;;
                    
                "all_ota_confirm")
                    CONFIRM_BTNS="[[{\"text\":\"🚨 我已了解风险，下发核按钮指令！\",\"callback_data\":\"all_ota_execute\"}], [{\"text\":\"取消操作\",\"callback_data\":\"/start\"}]]"
                    WARNING_MSG="☢️ **【远程批量升级】**\n\n此操作将向您名下**所有开启 OTA 权限的节点**下发升级指令，强制从云端拉取最新代码并进行热重载。\n\n⚠️ **风险提示**：\n1. 升级过程中守护进程会短暂重启，节点可能出现临时离线。\n2. 若遇 GitHub 源屏蔽或网络极度恶劣，少数节点可能需要手动干预。\n\n**是否确定下发 OTA 升级指令？**"
                    send_ui "$CHAT_ID" "$WARNING_MSG" "$CONFIRM_BTNS"
                    ;;

                "all_ota_execute")
                    NODE_DATA=$(execute_sqlite_query "SELECT node_name, agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID' AND enable_ota='true';")
                    if [ -z "$NODE_DATA" ]; then
                        send_msg "$CHAT_ID" "⚠️ 您名下暂无开启 OTA 权限的在线节点。"
                    else
                        send_msg "$CHAT_ID" "📢 **正在唤醒各节点执行 OTA 升级...**%0A*(节点升级成功后会主动发回新的入库确认，请注意查收)*"
                        echo "$NODE_DATA" | while IFS='|' read -r NNAME AIP APORT; do
                            dispatch_agent_request "$AIP" "$APORT" "/trigger_ota" "" "$NNAME" > /dev/null &
                            sleep 0.3
                        done
                    fi
                    ;;

                "master_ota_confirm")
                    CONFIRM_BTNS="[[{\"text\":\"🚨 确认重构司令部\",\"callback_data\":\"master_ota_execute\"}], [{\"text\":\"取消操作\",\"callback_data\":\"/start\"}]]"
                    WARNING_MSG="☢️ **【中枢系统重构】**\n\n此操作将拉取最新源码并强行覆盖司令部核心进程。\n\n⚠️ **风险提示**：\n升级期间司令部将短暂失联（约3-5秒）。完成后会自动发送捷报。\n\n**是否确定执行中枢系统升级？**"
                    if [ -n "$callback_message_id" ]; then
                        edit_ui "$CHAT_ID" "$callback_message_id" "$WARNING_MSG" "$CONFIRM_BTNS"
                    else
                        send_ui "$CHAT_ID" "$WARNING_MSG" "$CONFIRM_BTNS"
                    fi
                    ;;

                "master_ota_execute")
                    if [ -n "$callback_message_id" ]; then
                        edit_msg "$CHAT_ID" "$callback_message_id" "⏳ 正在拉取更新，中枢即将进入静默重启..."
                    else
                        send_msg "$CHAT_ID" "⏳ 正在拉取更新，中枢即将进入静默重启..."
                    fi

                    curl -fsSL "${REPO_RAW_URL}/master/install_master.sh" -o "/tmp/install_master.sh"
                    
                                if ! bash -n "/tmp/install_master.sh" >/dev/null 2>&1; then
                        if [ -n "$callback_message_id" ]; then
                            edit_msg "$CHAT_ID" "$callback_message_id" "❌ OTA 传输受损：脚本下载不完整，已触发熔断，升级取消！"
                        else
                            send_msg "$CHAT_ID" "❌ OTA 传输受损：脚本下载不完整，已触发熔断，升级取消！"
                        fi
                        continue
                    fi
                    
                    chmod +x "/tmp/install_master.sh"
                    
                    if command -v systemd-run >/dev/null 2>&1; then
                        systemd-run --quiet --no-block /bin/bash -c "export SILENT_MASTER_OTA='true'; export OTA_CHAT_ID='$CHAT_ID'; bash /tmp/install_master.sh"
                    else
                        export SILENT_MASTER_OTA="true"
                        export OTA_CHAT_ID="$CHAT_ID"
                        nohup bash /tmp/install_master.sh >/dev/null 2>&1 & disown
                    fi
                    sleep 10
                    ;;

                "all_reports")
                    NODE_DATA=$(execute_sqlite_query "SELECT node_name, agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID';")
                    if [ -z "$NODE_DATA" ]; then
                        send_msg "$CHAT_ID" "⚠️ 您名下暂无在线节点。"
                    else
                        NODE_COUNT=$(echo "$NODE_DATA" | grep -c '^')
                        send_msg "$CHAT_ID" "📢 **正在获取全局简报...**%0A*(已唤醒 ${NODE_COUNT} 个节点。由于防限流排队发送机制，简报将依次送达。若后台有刚启动的维护任务，最新数据将在任务完成后自动更新)*"
                        echo "$NODE_DATA" | while IFS='|' read -r NNAME AIP APORT; do
                            dispatch_agent_request "$AIP" "$APORT" "/trigger_report" "" "$NNAME" > /dev/null &
                            sleep 2  
                        done
                    fi
                    ;;

                "all_run")
                    NODE_DATA=$(execute_sqlite_query "SELECT node_name, agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID';")
                    if [ -z "$NODE_DATA" ]; then
                        send_msg "$CHAT_ID" "⚠️ 您名下暂无在线节点。"
                    else
                        NODE_COUNT=$(echo "$NODE_DATA" | grep -c '^')
                        send_msg "$CHAT_ID" "📢 **正在唤醒所有节点执行系统维护...**%0A*(已向 ${NODE_COUNT} 个节点下发维护指令。任务已在各节点后台异步启动，整轮耗时约 30-60 秒，完成后数据会自动更新)*"
                        echo "$NODE_DATA" | while IFS='|' read -r NNAME AIP APORT; do
                            dispatch_agent_request "$AIP" "$APORT" "/trigger_run" "" "$NNAME" > /dev/null &
                            sleep 0.2  
                        done
                    fi
                    ;;

                "/quality"|"/quality@"*)
                    TARGET_NODE=$(echo "$callback_payload" | awk '{print $2}')
                    if [ -z "$TARGET_NODE" ]; then
                        send_msg "$CHAT_ID" "⚠️ 请指定目标节点。例如: \`/quality HK-1\`%0A或通过雷达面板进行选择操作。"
                    else
                        TARGET_NODE=$(echo "$TARGET_NODE" | tr -cd 'a-zA-Z0-9_.-')
                        CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                        
                        AGENT_INFO=$(execute_sqlite_query "SELECT agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                        AGENT_IP=$(echo "$AGENT_INFO" | cut -d'|' -f1)
                        AGENT_PORT=$(echo "$AGENT_INFO" | cut -d'|' -f2)

                        if [ -n "$AGENT_IP" ] && [ -n "$AGENT_PORT" ]; then
                            send_msg "$CHAT_ID" "⏳ 正在向 \`$TARGET_NODE\` ($AGENT_IP) 下发 [quality] 指令，请稍候..."
                            
                            RESPONSE=$(dispatch_agent_request "$AGENT_IP" "$AGENT_PORT" "/trigger_quality" "" "$TARGET_NODE")
                            
                            if [ "$RESPONSE" == "FAILED" ]; then
                                send_msg "$CHAT_ID" "❌ 指令下发超时或失败！请检查节点公网 IP 或防火墙端口 ($AGENT_PORT) 是否放行."
                            elif [[ "$RESPONSE" == *"403"* ]]; then
                                send_msg "$CHAT_ID" "⚠️ **拒绝执行**：该节点未在本地开启此模块，请检查安装时的配置！"
                            elif [[ "$RESPONSE" == *"401"* ]]; then
                                send_msg "$CHAT_ID" "🚨 **鉴权失败**：中枢与节点的通信凭证 (Token) 不匹配，指令已被节点强行熔断！%0A%0A💡 *请在节点重新运行安装脚本，将生成的最新 \`#REGISTER#\` 注册指令发送给 Bot 进行同步！*"
                            else
                                send_msg "$CHAT_ID" "✅ 节点 \`$TARGET_NODE\` 回应: 🔍 体检探针已投放！请等待战报回传。"
                            fi
                        else
                            send_msg "$CHAT_ID" "❌ 数据库中未找到该节点的通讯地址。"
                        fi
                    fi
                    ;;

                "/trend"|"/trend@"*)
                    TARGET_NODE=$(echo "$callback_payload" | awk '{print $2}')
                    if [ -z "$TARGET_NODE" ]; then
                        send_msg "$CHAT_ID" "⚠️ 请指定目标节点。例如: \`/trend HK-1\`%0A或通过雷达面板进行选择操作。"
                    else
                        TARGET_NODE=$(echo "$TARGET_NODE" | tr -cd 'a-zA-Z0-9_.-')
                        CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                        
                        TREND_DATA=$(execute_sqlite_query "SELECT datetime(check_time, 'localtime'), scam_score, goog_status, nf_status, gpt_status FROM ip_trend_log WHERE node_name='$TARGET_NODE' ORDER BY check_time DESC LIMIT 15;")
                        
                        if [ -z "$TREND_DATA" ]; then
                            send_msg "$CHAT_ID" "⚠️ 节点 \`$TARGET_NODE\` 暂无历史体检档案。请先执行 /quality 投放探针进行探测。"
                        else
                            TARGET_ALIAS=$(execute_sqlite_query "SELECT IFNULL(node_alias, node_name) FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                            [ -z "$TARGET_ALIAS" ] && TARGET_ALIAS="$TARGET_NODE"

                            TEXT_RES="📈 *[${TARGET_ALIAS}] 历史态势感知 (近15次)*\n\n"
                            TEXT_RES+="时间(本地)  | 风险 | 谷歌 | NF | GPT\n"
                            TEXT_RES+="-----------------------------------------\n"
                            
                            while IFS='|' read -r c_time score goog nf gpt; do
                                [ -z "$score" ] && score="0"
                                [ -z "$goog" ] && goog="未知"
                                [ -z "$nf" ] && nf="未知"
                                [ -z "$gpt" ] && gpt="未知"
                                
                                short_time=$(echo "$c_time" | cut -c 6-16)
                                
                                if [ "$score" -le 20 ]; then SCORE_EMJ="🟢"
                                elif [ "$score" -le 60 ]; then SCORE_EMJ="🟡"
                                else SCORE_EMJ="🔴"
                                fi
                                
                                TEXT_RES+="\`${short_time}\` | ${SCORE_EMJ}\`${score}\` | \`${goog}\` | \`${nf}\` | \`${gpt}\`\n"
                            done <<< "$TREND_DATA"
                            TEXT_RES+="\n_💡 提示：🔴风险分 >60 极易触发网页验证码拦截；谷歌显示 CN 即为高危送中。_"
                            
                            BTNS="[[{\"text\":\"⚙️ 调出该节点控制台\",\"callback_data\":\"manage:$TARGET_NODE\"}]]"
                            send_ui "$CHAT_ID" "$TEXT_RES" "$BTNS"
                        fi
                    fi
                    ;;

                "list_nodes")
                    REGION_DATA=$(execute_sqlite_query "SELECT region, COUNT(*) FROM nodes WHERE chat_id='$CHAT_ID' GROUP BY region;")
                    if [ -z "$REGION_DATA" ]; then
                        send_msg "$CHAT_ID" "⚠️ 您名下暂无在线节点，请先在边缘机执行部署。"
                    else
                        BTNS="["
                        while IFS='|' read -r REGION_NAME NODE_COUNT; do
                            [ -z "$REGION_NAME" ] && REGION_NAME="UNKNOWN"
                        FLAG=$(get_flag "$REGION_NAME")
                        BTNS="$BTNS[{\"text\":\"$FLAG $REGION_NAME ($NODE_COUNT 台)\",\"callback_data\":\"region:$REGION_NAME\"}],"
                        done <<< "$REGION_DATA"
                        BTNS="$BTNS[{\"text\":\"🏠 回到控制中枢\",\"callback_data\":\"/start\"}]]"
                        send_ui "$CHAT_ID" "🌍 **全视界雷达面板**\n已为您聚合当前舰队的部署大区，请选择要检阅的区域：" "$BTNS"
                    fi
                    ;;

                region:*)
                    TARGET_REGION=$(echo "${callback_payload#*:}" | tr -cd 'a-zA-Z0-9')
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                    NODE_LIST=$(execute_sqlite_query "SELECT node_name, IFNULL(node_alias, node_name) FROM nodes WHERE chat_id='$CHAT_ID' AND region='$TARGET_REGION';")
                    if [ -z "$NODE_LIST" ]; then
                        send_msg "$CHAT_ID" "⚠️ 该区域下暂无可用节点。"
                    else
                        BTNS="["
                        COL=0
                        ROW_STR="["
                        while IFS='|' read -r N_NAME N_ALIAS; do
                            [ -z "$N_NAME" ] && continue
                            ROW_STR="$ROW_STR{\"text\":\"🖥️ $N_ALIAS\",\"callback_data\":\"manage:$N_NAME\"},"
                            COL=$((COL+1))
                            if [ $COL -eq 2 ]; then
                                ROW_STR="${ROW_STR%,}]"
                                BTNS="$BTNS$ROW_STR,"
                                COL=0
                                ROW_STR="["
                            fi
                        done <<< "$NODE_LIST"
                        if [ $COL -eq 1 ]; then
                            ROW_STR="${ROW_STR%,}]"
                            BTNS="$BTNS$ROW_STR,"
                        fi
                        BTNS="$BTNS[{\"text\":\"⬅️ 返回区域地图\",\"callback_data\":\"list_nodes\"}, {\"text\":\"🏠 回到控制中枢\",\"callback_data\":\"/start\"}]]"
                        send_ui "$CHAT_ID" "📍 **[$TARGET_REGION] 区域节点矩阵**\n请选择要操作的具体节点目标：" "$BTNS"
                    fi
                    ;;

                manage:*)
                    TARGET_NODE=$(echo "${callback_payload#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    TARGET_ALIAS=$(execute_sqlite_query "SELECT IFNULL(node_alias, node_name) FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    [ -z "$TARGET_ALIAS" ] && TARGET_ALIAS="$TARGET_NODE"
                    
                    TOGGLE_INFO=$(execute_sqlite_query "SELECT enable_google, enable_trust, enable_ota, agent_ip, IFNULL(last_seen, '未知') FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    ST_GOOGLE=$(echo "$TOGGLE_INFO" | cut -d'|' -f1)
                    ST_TRUST=$(echo "$TOGGLE_INFO" | cut -d'|' -f2)
                    ST_OTA=$(echo "$TOGGLE_INFO" | cut -d'|' -f3)
                    A_IP=$(echo "$TOGGLE_INFO" | cut -d'|' -f4)
                    LAST_SEEN=$(echo "$TOGGLE_INFO" | cut -d'|' -f5)
                    
                    [ "$ST_GOOGLE" == "true" ] && BTN_G="🟢 Google巡逻: 已开" && ACT_G="false" || { BTN_G="🔴 Google巡逻: 已停"; ACT_G="true"; }
                    [ "$ST_TRUST" == "true" ] && BTN_T="🟢 信用净化: 已开" && ACT_T="false" || { BTN_T="🔴 信用净化: 已停"; ACT_T="true"; }

                    BTN_ACTION="[{\"text\":\"📍 触发 Google 纠偏\",\"callback_data\":\"google:$TARGET_NODE\"}, {\"text\":\"🛡️ 触发信用净化\",\"callback_data\":\"trust:$TARGET_NODE\"}], [{\"text\":\"🔍 投放体检探针 (查IP质量)\",\"callback_data\":\"quality:$TARGET_NODE\"}, {\"text\":\"📈 查看 IP 污染趋势图\",\"callback_data\":\"trend:$TARGET_NODE\"}], [{\"text\":\"📜 提取终端实时日志\",\"callback_data\":\"log:$TARGET_NODE\"}, {\"text\":\"📊 生成单机战报\",\"callback_data\":\"report:$TARGET_NODE\"}]"
                    BTN_TOGGLE="[{\"text\":\"$BTN_G\",\"callback_data\":\"toggle:google:$TARGET_NODE:$ACT_G\"}, {\"text\":\"$BTN_T\",\"callback_data\":\"toggle:trust:$TARGET_NODE:$ACT_T\"}]"

                    if [ "$IS_OFFICIAL_GATEWAY" != "true" ] && [ "$ST_OTA" == "true" ]; then
                        BTN_CONFIG="[{\"text\":\"✏️ 更改终端展示代号\",\"callback_data\":\"rename:$TARGET_NODE\"}, {\"text\":\"🆙 OTA 静默升级\",\"callback_data\":\"ota_confirm:$TARGET_NODE\"}]"
                    else
                        BTN_CONFIG="[{\"text\":\"✏️ 更改终端展示代号\",\"callback_data\":\"rename:$TARGET_NODE\"}]"
                    fi
                    
                    # 变更 callback_data 由 del 变为 del_confirm
BTN_DANGER="[{\"text\":\"🗑️ 从中枢销毁该档案\",\"callback_data\":\"del_confirm:$TARGET_NODE\"}, {\"text\":\"⬅️ 返回区域列表\",\"callback_data\":\"list_nodes\"}]"

                    BTNS="[$BTN_ACTION, $BTN_TOGGLE, $BTN_CONFIG, $BTN_DANGER]"
                    TEXT_MSG="⚙️ **目标锁定**: \`$TARGET_ALIAS\`\n(底层标识: \`$TARGET_NODE\`)\n🌐 IP 坐标: \`$A_IP\`\n🕒 最后通讯: \`$LAST_SEEN\`\n\n请下达精确控制指令："

                    if [ -n "$callback_message_id" ]; then
                        edit_ui "$CHAT_ID" "$callback_message_id" "$TEXT_MSG" "$BTNS"
                    else
                        send_ui "$CHAT_ID" "$TEXT_MSG" "$BTNS"
                    fi
                    ;;

                toggle:*)
                    IFS=':' read -r CMD MOD_NAME TARGET_NODE TARGET_STATE <<< "$callback_payload"
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                    AGENT_INFO=$(execute_sqlite_query "SELECT agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    AGENT_IP=$(echo "$AGENT_INFO" | cut -d'|' -f1)
                    AGENT_PORT=$(echo "$AGENT_INFO" | cut -d'|' -f2)
                    
                    if [ -n "$AGENT_IP" ] && [ -n "$AGENT_PORT" ]; then
                        RESPONSE=$(dispatch_agent_request "$AGENT_IP" "$AGENT_PORT" "/trigger_toggle" "mod=${MOD_NAME}&state=${TARGET_STATE}" "$TARGET_NODE")
                        
                        if [[ "$RESPONSE" == *"Action Accepted"* ]]; then
                            execute_sqlite_query "UPDATE nodes SET enable_${MOD_NAME}='$TARGET_STATE' WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE';"
                            
                            TOGGLE_INFO=$(execute_sqlite_query "SELECT enable_google, enable_trust FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                            ST_GOOGLE=$(echo "$TOGGLE_INFO" | cut -d'|' -f1)
                            ST_TRUST=$(echo "$TOGGLE_INFO" | cut -d'|' -f2)
                            [ "$ST_GOOGLE" == "true" ] && BTN_G="🔴 停用 Google 纠偏" && ACT_G="false" || { BTN_G="🟢 启用 Google 纠偏"; ACT_G="true"; }
                            [ "$ST_TRUST" == "true" ] && BTN_T="🔴 停用信用净化" && ACT_T="false" || { BTN_T="🟢 启用信用净化"; ACT_T="true"; }
                            
                            TOGGLE_INFO=$(execute_sqlite_query "SELECT enable_google, enable_trust, enable_ota, agent_ip, IFNULL(last_seen, '未知') FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                            ST_GOOGLE=$(echo "$TOGGLE_INFO" | cut -d'|' -f1)
                            ST_TRUST=$(echo "$TOGGLE_INFO" | cut -d'|' -f2)
                            ST_OTA=$(echo "$TOGGLE_INFO" | cut -d'|' -f3)
                            A_IP=$(echo "$TOGGLE_INFO" | cut -d'|' -f4)
                            LAST_SEEN=$(echo "$TOGGLE_INFO" | cut -d'|' -f5)

                            [ "$ST_GOOGLE" == "true" ] && BTN_G="🟢 Google巡逻: 已开" && ACT_G="false" || { BTN_G="🔴 Google巡逻: 已停"; ACT_G="true"; }
                            [ "$ST_TRUST" == "true" ] && BTN_T="🟢 信用净化: 已开" && ACT_T="false" || { BTN_T="🔴 信用净化: 已停"; ACT_T="true"; }

                            BTN_ACTION="[{\"text\":\"📍 触发 Google 纠偏\",\"callback_data\":\"google:$TARGET_NODE\"}, {\"text\":\"🛡️ 触发信用净化\",\"callback_data\":\"trust:$TARGET_NODE\"}], [{\"text\":\"🔍 投放体检探针 (查IP质量)\",\"callback_data\":\"quality:$TARGET_NODE\"}, {\"text\":\"📈 查看 IP 污染趋势图\",\"callback_data\":\"trend:$TARGET_NODE\"}], [{\"text\":\"📜 提取终端实时日志\",\"callback_data\":\"log:$TARGET_NODE\"}, {\"text\":\"📊 生成单机战报\",\"callback_data\":\"report:$TARGET_NODE\"}]"
                            BTN_TOGGLE="[{\"text\":\"$BTN_G\",\"callback_data\":\"toggle:google:$TARGET_NODE:$ACT_G\"}, {\"text\":\"$BTN_T\",\"callback_data\":\"toggle:trust:$TARGET_NODE:$ACT_T\"}]"
                            
                            if [ "$IS_OFFICIAL_GATEWAY" != "true" ] && [ "$ST_OTA" == "true" ]; then
                                BTN_CONFIG="[{\"text\":\"✏️ 更改终端展示代号\",\"callback_data\":\"rename:$TARGET_NODE\"}, {\"text\":\"🆙 OTA 静默升级\",\"callback_data\":\"ota_confirm:$TARGET_NODE\"}]"
                            else
                                BTN_CONFIG="[{\"text\":\"✏️ 更改终端展示代号\",\"callback_data\":\"rename:$TARGET_NODE\"}]"
                            fi
                            BTN_DANGER="[{\"text\":\"🗑️ 从中枢销毁该档案\",\"callback_data\":\"del:$TARGET_NODE\"}, {\"text\":\"⬅️ 返回区域列表\",\"callback_data\":\"list_nodes\"}]"

                            BTNS="[$BTN_ACTION, $BTN_TOGGLE, $BTN_CONFIG, $BTN_DANGER]"
                            TARGET_ALIAS=$(execute_sqlite_query "SELECT IFNULL(node_alias, node_name) FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                            
                            TEXT_MSG="⚙️ **目标锁定**: \`$TARGET_ALIAS\`\n(底层标识: \`$TARGET_NODE\`)\n🌐 IP 坐标: \`$A_IP\`\n🕒 最后通讯: \`$LAST_SEEN\`\n\n✅ **执行成功**: 模块 [$MOD_NAME] 状态已切换为 $TARGET_STATE！"
                            edit_ui "$CHAT_ID" "$callback_message_id" "$TEXT_MSG" "$BTNS"
                        elif [[ "$RESPONSE" == *"401"* ]]; then
                            send_msg "$CHAT_ID" "🚨 **鉴权失败**：中枢与节点的通信凭证 (Token) 不匹配，指令已被节点强行熔断！%0A%0A💡 *请在节点重新运行安装脚本，将生成的最新 \`#REGISTER#\` 注册指令发送给 Bot 进行同步！*"
                        else
                            send_msg "$CHAT_ID" "❌ 指令下发失败，安全策略禁止降级重试。"
                        fi
                    fi
                    ;;

                del_confirm:*)
                    TARGET_NODE=$(echo "${callback_payload#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    TARGET_ALIAS=$(execute_sqlite_query "SELECT IFNULL(node_alias, node_name) FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    [ -z "$TARGET_ALIAS" ] && TARGET_ALIAS="$TARGET_NODE"
                    
                    CONFIRM_BTNS="[[{\"text\":\"🚨 确定永久销毁该档案\",\"callback_data\":\"del_execute:$TARGET_NODE\"}], [{\"text\":\"取消操作\",\"callback_data\":\"manage:$TARGET_NODE\"}]]"
                    WARNING_MSG="☢️ **【高危操作：销毁节点档案】**\n\n您即将从司令部彻底抹除节点 \`$TARGET_ALIAS\` 的追踪数据。\n\n⚠️ **风险提示**：\n1. 中枢数据库将永久丢失该节点的存活记录与 IP 污染体检趋势历史。\n2. 若边缘节点的 Agent 进程仍在运行，其下一次发送探测报告时将因未注册被中枢抛弃。\n\n**是否确定执行销毁动作？**"
                    
                    if [ -n "$callback_message_id" ]; then
                        edit_ui "$CHAT_ID" "$callback_message_id" "$WARNING_MSG" "$CONFIRM_BTNS"
                    else
                        send_ui "$CHAT_ID" "$WARNING_MSG" "$CONFIRM_BTNS"
                    fi
                    ;;

                del_execute:*)
                    TARGET_NODE=$(echo "${callback_payload#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                            VALID_OWNER=$(execute_sqlite_query "SELECT 1 FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    
                    if [ "$VALID_OWNER" == "1" ]; then
                        execute_sqlite_query "DELETE FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE';"
                        execute_sqlite_query "DELETE FROM ip_trend_log WHERE node_name='$TARGET_NODE';"
                        
                                    if [ -n "$callback_message_id" ]; then
                            edit_msg "$CHAT_ID" "$callback_message_id" "🗑️ 节点 \`$TARGET_NODE\` 的档案及污染趋势历史已被强行抹除。"
                        else
                            send_msg "$CHAT_ID" "🗑️ 节点 \`$TARGET_NODE\` 的档案及历史污染趋势已从中枢彻底销毁！"
                        fi
                    else
                        if [ -n "$callback_message_id" ]; then
                            edit_msg "$CHAT_ID" "$callback_message_id" "⛔ **安全拦截**：销毁失败。目标节点不存在或您无权越权操作！"
                        else
                            send_msg "$CHAT_ID" "⛔ **安全拦截**：销毁失败。目标节点不存在或您无权越权操作！"
                        fi
                        continue
                    fi
                    
                            REGION_DATA=$(execute_sqlite_query "SELECT region, COUNT(*) FROM nodes WHERE chat_id='$CHAT_ID' GROUP BY region;")
                    if [ -z "$REGION_DATA" ]; then
                        send_msg "$CHAT_ID" "⚠️ 当前中枢已无任何节点挂载。"
                    else
                        BTNS="["
                        while IFS='|' read -r REGION_NAME NODE_COUNT; do
                            [ -z "$REGION_NAME" ] && REGION_NAME="UNKNOWN"
                            FLAG=$(get_flag "$REGION_NAME")
                            BTNS="$BTNS[{\"text\":\"$FLAG $REGION_NAME ($NODE_COUNT 台)\",\"callback_data\":\"region:$REGION_NAME\"}],"
                        done <<< "$REGION_DATA"
                        BTNS="$BTNS[{\"text\":\"🏠 回到控制中枢\",\"callback_data\":\"/start\"}]]"
                        send_ui "$CHAT_ID" "🌍 刷新后的全视界雷达：" "$BTNS"
                    fi
                    ;;

                rename:*)
                    TARGET_NODE=$(echo "${callback_payload#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
                        -H "Content-Type: application/json" \
                        -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"✏️ 请回复本消息以重命名节点:\n\`$TARGET_NODE\`\n(仅限中英文、数字，最长20字符)\",\"parse_mode\":\"Markdown\",\"reply_markup\":{\"force_reply\":true}}" > /dev/null
                    ;;

                do_rename:*)
                    IFS=':' read -r CMD TARGET_NODE NEW_ALIAS <<< "$callback_payload"
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                    AGENT_INFO=$(execute_sqlite_query "SELECT agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    AGENT_IP=$(echo "$AGENT_INFO" | cut -d'|' -f1)
                    AGENT_PORT=$(echo "$AGENT_INFO" | cut -d'|' -f2)

                    if [ -n "$AGENT_IP" ] && [ -n "$AGENT_PORT" ]; then
                        send_msg "$CHAT_ID" "⏳ 正在向 \`$TARGET_NODE\` 下发重命名指令，正在建立加密隧道..."
                        
                                    ALIAS_B64=$(echo -n "$NEW_ALIAS" | base64 | tr -d '\n' | tr '+/' '-_')
                        RESPONSE=$(dispatch_agent_request "$AGENT_IP" "$AGENT_PORT" "/trigger_rename" "b64=${ALIAS_B64}" "$TARGET_NODE")
                        
                        if [ "$RESPONSE" == "FAILED" ]; then
                            send_msg "$CHAT_ID" "❌ 指令下发超时！为防范劫持风险，已终止请求。"
                        elif [[ "$RESPONSE" == *"401"* ]]; then
                            send_msg "$CHAT_ID" "🚨 **鉴权失败**：中枢与节点的通信凭证 (Token) 不匹配，指令已被节点强行熔断！%0A%0A💡 *请在节点重新运行安装脚本，将生成的最新 \`#REGISTER#\` 注册指令发送给 Bot 进行同步！*"
                        elif [[ "$RESPONSE" == *"Action Accepted"* ]]; then
                            execute_sqlite_query "UPDATE nodes SET node_alias='$NEW_ALIAS' WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE';"
                            send_msg "$CHAT_ID" "✅ 通讯成功！节点别名已下发: \`$NEW_ALIAS\`%0A*(中枢档案已自动刷新，雷达面板已同步)*"
                        else
                            send_msg "$CHAT_ID" "⚠️ 节点拒绝了请求，请确保 Agent 已更新至 v3.5.2%0A(回传信息: \`${RESPONSE}\`)"
                        fi
                    else
                        send_msg "$CHAT_ID" "❌ 数据库中未找到该节点的通讯地址。"
                    fi
                    ;;

                ota_confirm:*)
                    TARGET_NODE=$(echo "${callback_payload#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    CONFIRM_BTNS="[[{\"text\":\"🚨 确认执行远程升级\",\"callback_data\":\"ota_execute:$TARGET_NODE\"}], [{\"text\":\"取消\",\"callback_data\":\"manage:$TARGET_NODE\"}]]"
                    send_ui "$CHAT_ID" "☢️ **操作确认**：即将向 \`$TARGET_NODE\` 下发 OTA 热更新指令。\n节点更新完成后会自动发送包含新版本号的注册回执，确定执行？" "$CONFIRM_BTNS"
                    ;;

                ota_execute:*)
                    TARGET_NODE=$(echo "${callback_payload#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                    AGENT_INFO=$(execute_sqlite_query "SELECT agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    AGENT_IP=$(echo "$AGENT_INFO" | cut -d'|' -f1)
                    AGENT_PORT=$(echo "$AGENT_INFO" | cut -d'|' -f2)

                            if [ -n "$AGENT_IP" ] && [ -n "$AGENT_PORT" ]; then
                        if [ -n "$callback_message_id" ]; then
                            edit_msg "$CHAT_ID" "$callback_message_id" "⏳ 正在向 \`$TARGET_NODE\` 发送 OTA 触发报文..."
                        else
                            send_msg "$CHAT_ID" "⏳ 正在向 \`$TARGET_NODE\` 发送 OTA 触发报文..."
                        fi
                        
                        RESPONSE=$(dispatch_agent_request "$AGENT_IP" "$AGENT_PORT" "/trigger_ota" "" "$TARGET_NODE")
                        
                        if [ "$RESPONSE" == "FAILED" ]; then
                            TEXT_RES="❌ OTA 指令下发彻底失败！链路异常或严禁使用 HTTP 降级通讯。"
                        elif [[ "$RESPONSE" == *"403"* ]]; then
                            TEXT_RES="⚠️ **节点拒绝执行**：该节点本地未开启 OTA 权限或运行在官方网关下！"
                        elif [[ "$RESPONSE" == *"401"* ]]; then
                            TEXT_RES="🚨 **鉴权失败**：中枢与节点的通信凭证 (Token) 不匹配，指令已被节点强行熔断！%0A%0A💡 *请在节点重新运行安装脚本，将生成的最新 \`#REGISTER#\` 注册指令发送给 Bot 进行同步！*"
                        else
                            TEXT_RES="✅ OTA (TLS加密) 触发成功！节点正在后台执行拉取重构..."
                        fi
                        
                        if [ -n "$callback_message_id" ]; then
                            edit_msg "$CHAT_ID" "$callback_message_id" "$TEXT_RES"
                        else
                            send_msg "$CHAT_ID" "$TEXT_RES"
                        fi
                    else
                        send_msg "$CHAT_ID" "❌ 数据库中未找到该节点的通讯地址。"
                    fi
                    ;;

                google:*|trust:*|run:*|report:*|log:*|quality:*)
                    ACTION_TYPE=$(echo "$callback_payload" | cut -d':' -f1)
                    TARGET_NODE=$(echo "$callback_payload" | cut -d':' -f2 | tr -cd 'a-zA-Z0-9_.-')
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                    AGENT_INFO=$(execute_sqlite_query "SELECT agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    AGENT_IP=$(echo "$AGENT_INFO" | cut -d'|' -f1)
                    AGENT_PORT=$(echo "$AGENT_INFO" | cut -d'|' -f2)

                            if [ -n "$AGENT_IP" ] && [ -n "$AGENT_PORT" ]; then
                        if [ -n "$callback_message_id" ]; then
                            edit_msg "$CHAT_ID" "$callback_message_id" "⏳ 正在向 \`$TARGET_NODE\` ($AGENT_IP) 下发 [$ACTION_TYPE] 指令，请稍候..."
                        else
                            send_msg "$CHAT_ID" "⏳ 正在向 \`$TARGET_NODE\` ($AGENT_IP) 下发 [$ACTION_TYPE] 指令，请稍候..."
                        fi
                        
                        RESPONSE=$(dispatch_agent_request "$AGENT_IP" "$AGENT_PORT" "/trigger_${ACTION_TYPE}" "" "$TARGET_NODE")
                        
                        if [ "$RESPONSE" == "FAILED" ]; then
                            TEXT_RES="❌ 指令下发超时或失败！为保护链路安全，已终止通信 (严禁降级为 HTTP)。"
                        elif [[ "$RESPONSE" == *"403"* ]]; then
                            TEXT_RES="⚠️ **拒绝执行**：该节点未在本地开启此模块，请检查安装时的配置！"
                        elif [[ "$RESPONSE" == *"401"* ]]; then
                            TEXT_RES="🚨 **鉴权失败**：中枢与节点的通信凭证 (Token) 不匹配，指令已被节点强行熔断！%0A%0A💡 *请在节点重新运行安装脚本，将生成的最新 \`#REGISTER#\` 注册指令发送给 Bot 进行同步！*"
                        else
                             if [ "$ACTION_TYPE" == "google" ]; then 
                                TEXT_RES="✅ 节点 \`$TARGET_NODE\` 回应: 📍 Google 纠偏程序启动。"
                            elif [ "$ACTION_TYPE" == "run" ]; then 
                                TEXT_RES="✅ 节点 \`$TARGET_NODE\` 回应: ⚙️ 系统维护与巡逻程序已启动。*(任务正在后台异步执行，最新数据将在本轮结束后自动更新)*"
                            elif [ "$ACTION_TYPE" == "trust" ]; then 
                                TEXT_RES="✅ 节点 \`$TARGET_NODE\` 回应: 🛡️ IP 信用净化程序启动。"
                            elif [ "$ACTION_TYPE" == "quality" ]; then 
                                TEXT_RES="✅ 节点 \`$TARGET_NODE\` 回应: 🔍 体检探针已投放！请等待战报回传。"
                            elif [ "$ACTION_TYPE" == "log" ]; then 
                                TEXT_RES="✅ 节点 \`$TARGET_NODE\` 正在抓取日志..."
                            elif [ "$ACTION_TYPE" == "report" ]; then 
                                TEXT_RES="✅ 节点 \`$TARGET_NODE\` 回应: 📊 正在生成并回传单机战报..."
                            else 
                                TEXT_RES="✅ 节点 \`$TARGET_NODE\` 接收指令: $ACTION_TYPE"
                            fi
                        fi
                        
                        if [ -n "$callback_message_id" ]; then
                            edit_msg "$CHAT_ID" "$callback_message_id" "$TEXT_RES"
                        else
                            send_msg "$CHAT_ID" "$TEXT_RES"
                        fi
                    else
                        send_msg "$CHAT_ID" "❌ 数据库中未找到该节点的通讯地址。"
                    fi
                    ;;

                trend:*)
                            TARGET_NODE=$(echo "${callback_payload#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                    TREND_DATA=$(execute_sqlite_query "SELECT datetime(check_time, 'localtime'), scam_score, goog_status, nf_status, gpt_status FROM ip_trend_log WHERE node_name='$TARGET_NODE' ORDER BY check_time DESC LIMIT 15;")
                    
                    if [ -z "$TREND_DATA" ]; then
                        TEXT_RES="⚠️ 节点 \`$TARGET_NODE\` 暂无历史体检档案。请先执行 [🔍 投放体检探针] 进行探测。"
                    else
                        TARGET_ALIAS=$(execute_sqlite_query "SELECT IFNULL(node_alias, node_name) FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                        [ -z "$TARGET_ALIAS" ] && TARGET_ALIAS="$TARGET_NODE"

                        TEXT_RES="📈 *[${TARGET_ALIAS}] 历史态势感知 (近15次)*\n\n"
                        TEXT_RES+="时间(本地)  | 风险 | 谷歌 | NF | GPT\n"
                        TEXT_RES+="-----------------------------------------\n"
                        
                        while IFS='|' read -r c_time score goog nf gpt; do
                            [ -z "$score" ] && score="0"
                            [ -z "$goog" ] && goog="未知"
                            [ -z "$nf" ] && nf="未知"
                            [ -z "$gpt" ] && gpt="未知"
                            
                            short_time=$(echo "$c_time" | cut -c 6-16)
                            
                            if [ "$score" -le 20 ]; then SCORE_EMJ="🟢"
                            elif [ "$score" -le 60 ]; then SCORE_EMJ="🟡"
                            else SCORE_EMJ="🔴"
                            fi
                            
                            TEXT_RES+="\`${short_time}\` | ${SCORE_EMJ}\`${score}\` | \`${goog}\` | \`${nf}\` | \`${gpt}\`\n"
                        done <<< "$TREND_DATA"
                        TEXT_RES+="\n_💡 提示：🔴风险分 >60 极易触发网页验证码拦截；谷歌显示 CN 即为高危送中。_"
                    fi
                    
                    BTNS="[[{\"text\":\"⚙️ 调出该节点控制台\",\"callback_data\":\"manage:$TARGET_NODE\"}]]"
                    
                    if [ -n "$callback_message_id" ]; then
                        edit_ui "$CHAT_ID" "$callback_message_id" "$TEXT_RES" "$BTNS"
                    else
                        send_ui "$CHAT_ID" "$TEXT_RES" "$BTNS"
                    fi
                    ;;
                    
            esac
        done
    fi
    sleep 1
done