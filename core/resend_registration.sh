#!/bin/bash

CURL_BIN=${CURL_BIN:-curl}
JQ_BIN=${JQ_BIN:-jq}
IP_BIN=${IP_BIN:-ip}

is_public_ip_literal() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$1" <<'PY'
import ipaddress
import sys

value = sys.argv[1].strip("[]")
try:
    address = ipaddress.ip_address(value)
except ValueError:
    raise SystemExit(1)
if not address.is_global or address.is_multicast or address.is_unspecified or address.is_reserved:
    raise SystemExit(1)
PY
}

is_public_communication_addresses() {
    local raw_addresses=${1//_/,}
    local address
    local address_list=()

    IFS=',' read -r -a address_list <<< "$raw_addresses"
    [ "${#address_list[@]}" -gt 0 ] || return 1
    for address in "${address_list[@]}"; do
        [ -n "$address" ] || return 1
        is_public_ip_literal "$address" || return 1
    done
}

probe_public_ip() {
    local family="$1"
    local probe_url
    local detected_address
    shift

    for probe_url in "$@"; do
        detected_address=$("$CURL_BIN" "-$family" -fsS -m 3 "$probe_url" 2>/dev/null | tr -d '[:space:]') || true
        if is_public_ip_literal "$detected_address"; then
            printf '%s' "$detected_address"
            return 0
        fi
    done
    return 1
}

detect_current_communication_addresses() {
    local detected_v4=""
    local detected_v6=""
    local route_device=""

    if [ -n "${RESEND_DETECTED_COMM_IP:-}" ]; then
        printf '%s' "$RESEND_DETECTED_COMM_IP"
        return 0
    fi

    detected_v4=$(probe_public_ip 4 https://api.ip.sb/ip https://ifconfig.me https://ipv4.icanhazip.com) || true
    if [ -n "$detected_v4" ]; then
        route_device=$("$IP_BIN" route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
        if [[ "$route_device" =~ ^(warp|wgcf|tun|tap|docker|br-|lo) ]] || [[ "$detected_v4" =~ ^104\.28\. ]]; then
            detected_v4=""
        fi
    else
        detected_v4=""
    fi

    detected_v6=$(probe_public_ip 6 https://api.ip.sb/ip https://ifconfig.me https://ipv6.icanhazip.com) || true
    if [ -n "$detected_v6" ]; then
        route_device=$("$IP_BIN" -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n 1)
        if [[ "$route_device" =~ ^(warp|wgcf|tun|tap|docker|br-|lo) ]]; then
            detected_v6=""
        fi
    else
        detected_v6=""
    fi

    if [ -n "$detected_v4" ] && [ -n "$detected_v6" ]; then
        printf '%s_[%s]' "$detected_v4" "$detected_v6"
    elif [ -n "$detected_v4" ]; then
        printf '%s' "$detected_v4"
    elif [ -n "$detected_v6" ]; then
        printf '[%s]' "$detected_v6"
    fi
}

refresh_registration_address() {
    local detected_address
    local address_choice=${RESEND_ADDRESS_CHOICE:-ask}

    detected_address=$(detect_current_communication_addresses)
    [ -n "$detected_address" ] || return 0
    [ "$detected_address" == "$COMM_IP" ] && return 0

    if [ "$address_choice" == "ask" ] && [ -t 0 ]; then
        printf '检测到当前公网通讯地址为 %s，配置中为 %s。使用当前地址？[Y/n] ' \
            "$detected_address" "$COMM_IP" >&2
        IFS= read -r address_choice
        address_choice=${address_choice:-detected}
    fi

    case "$address_choice" in
        detected|y|Y|yes|YES)
            COMM_IP="$detected_address"
            ;;
        config|n|N|no|NO|ask)
            ;;
        *)
            echo "❌ 通讯地址选择无效。" >&2
            return 1
            ;;
    esac
}

load_registration_config() {
    local config_file="$1"
    local required_name
    local required_value

    if [ ! -r "$config_file" ]; then
        echo "❌ 找不到节点配置：$config_file" >&2
        return 1
    fi

    unset REGION_CODE REGION_NAME NODE_NAME COMM_IP AGENT_PORT NODE_ALIAS ENABLE_OTA AGENT_TOKEN TG_API_URL CHAT_ID
    # 节点配置由安装程序生成，且仅允许 root 读写。
    source "$config_file"

    for required_name in REGION_CODE NODE_NAME COMM_IP AGENT_PORT NODE_ALIAS ENABLE_OTA AGENT_TOKEN TG_API_URL CHAT_ID; do
        required_value=${!required_name:-}
        if [ -z "$required_value" ]; then
            echo "❌ 节点配置缺少 $required_name，不能重新发送注册信息。" >&2
            return 1
        fi
        if [[ "$required_value" == *"|"* || "$required_value" == *$'\n'* || "$required_value" == *$'\r'* ]]; then
            echo "❌ 节点配置中的 $required_name 格式无效。" >&2
            return 1
        fi
    done

    [[ "$NODE_NAME" =~ ^[a-zA-Z0-9_.-]+$ ]] || {
        echo "❌ NODE_NAME 格式无效。" >&2
        return 1
    }
    [[ "$AGENT_PORT" =~ ^[0-9]{1,5}$ ]] || {
        echo "❌ AGENT_PORT 格式无效。" >&2
        return 1
    }
    [ "$AGENT_PORT" -ge 1 ] && [ "$AGENT_PORT" -le 65535 ] || {
        echo "❌ AGENT_PORT 超出有效范围。" >&2
        return 1
    }
    is_public_communication_addresses "$COMM_IP" || {
        echo "❌ COMM_IP 必须是公网 IP。" >&2
        return 1
    }
    [[ "$ENABLE_OTA" == "true" || "$ENABLE_OTA" == "false" ]] || {
        echo "❌ ENABLE_OTA 只能是 true 或 false。" >&2
        return 1
    }
    [[ "$AGENT_TOKEN" =~ ^[a-fA-F0-9]{32,128}$ ]] || {
        echo "❌ AGENT_TOKEN 格式无效；请先升级节点。" >&2
        return 1
    }
    [[ "$TG_API_URL" =~ ^https:// ]] || {
        echo "❌ TG_API_URL 必须使用 HTTPS。" >&2
        return 1
    }
    [[ "$CHAT_ID" =~ ^-?[0-9]+$ ]] || {
        echo "❌ CHAT_ID 格式无效。" >&2
        return 1
    }
}

build_registration_record() {
    printf '#REGISTER#|%s|%s|%s|%s|%s|%s|%s' \
        "$REGION_CODE" "$NODE_NAME" "$COMM_IP" "$AGENT_PORT" "$NODE_ALIAS" "$ENABLE_OTA" "$AGENT_TOKEN"
}

build_registration_message() {
    local registration_record
    registration_record=$(build_registration_record)

    printf '📨 *节点注册信息*\n📍 节点：`%s`\n🌐 通讯地址：`%s`\n\n请复制下面整行并发送给机器人：\n`%s`' \
        "$NODE_ALIAS" "$COMM_IP" "$registration_record"
}

send_registration_message() {
    local message="$1"
    local payload
    local response

    command -v "$CURL_BIN" >/dev/null 2>&1 || {
        echo "❌ 找不到 curl。" >&2
        return 1
    }
    command -v "$JQ_BIN" >/dev/null 2>&1 || {
        echo "❌ 找不到 jq。" >&2
        return 1
    }

    payload=$("$JQ_BIN" -n --arg cid "$CHAT_ID" --arg txt "$message" \
        '{chat_id: $cid, text: $txt, parse_mode: "Markdown"}') || return 1
    response=$("$CURL_BIN" -fsS -X POST "$TG_API_URL" \
        -H "Content-Type: application/json" -d "$payload") || return 1

    echo "$response" | grep -q '"ok":true'
}

main() {
    local config_file=${1:-/opt/ip_sentinel/config.conf}
    local mode=${2:-send}
    local message

    load_registration_config "$config_file" || return 1
    if [ "$mode" != "--print-only" ]; then
        refresh_registration_address || return 1
    fi
    message=$(build_registration_message)

    if [ "$mode" == "--print-only" ]; then
        printf '%s\n' "$message"
        return 0
    fi

    if send_registration_message "$message"; then
        echo "✅ 注册信息已发送。请将消息中的注册指令发给机器人完成同步。"
        return 0
    fi

    echo "❌ 注册信息发送失败，请检查网络、机器人配置和 Chat ID。" >&2
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
