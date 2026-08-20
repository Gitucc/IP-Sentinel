#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${REPO_ROOT}/core/resend_registration.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

cat > "${TEST_DIR}/valid.conf" <<'EOF'
REGION_CODE="US"
REGION_NAME="United States - California (Irvine)"
NODE_NAME="US-Irvine-1"
COMM_IP="1.1.1.1_[2606:4700:4700::1111]"
AGENT_PORT="9527"
NODE_ALIAS="Irvine-1"
ENABLE_OTA="true"
AGENT_TOKEN="0123456789abcdef0123456789abcdef"
TG_API_URL="https://api.telegram.org/botTEST/sendMessage"
CHAT_ID="-1001234567890"
EOF

cat > "${TEST_DIR}/missing-token.conf" <<'EOF'
REGION_CODE="US"
NODE_NAME="US-Irvine-1"
COMM_IP="1.1.1.1"
AGENT_PORT="9527"
NODE_ALIAS="Irvine-1"
ENABLE_OTA="true"
TG_API_URL="https://api.telegram.org/botTEST/sendMessage"
CHAT_ID="123456789"
EOF

load_registration_config "${TEST_DIR}/valid.conf"
EXPECTED="#REGISTER#|US|US-Irvine-1|1.1.1.1_[2606:4700:4700::1111]|9527|Irvine-1|true|0123456789abcdef0123456789abcdef"
ACTUAL=$(build_registration_record)
[ "$ACTUAL" == "$EXPECTED" ] || {
    echo "FAIL: registration record changed" >&2
    exit 1
}

RESEND_DETECTED_COMM_IP="9.9.9.9_[2606:4700:4700::1001]"
RESEND_ADDRESS_CHOICE="detected"
refresh_registration_address
[ "$COMM_IP" == "$RESEND_DETECTED_COMM_IP" ] || {
    echo "FAIL: detected address was not selected" >&2
    exit 1
}
load_registration_config "${TEST_DIR}/valid.conf"
RESEND_ADDRESS_CHOICE="config"
refresh_registration_address
[ "$COMM_IP" == "1.1.1.1_[2606:4700:4700::1111]" ] || {
    echo "FAIL: configured address was not retained" >&2
    exit 1
}
unset RESEND_DETECTED_COMM_IP RESEND_ADDRESS_CHOICE

MESSAGE=$(build_registration_message)
[[ "$MESSAGE" == *$'\n'* ]] || {
    echo "FAIL: message has no real newline" >&2
    exit 1
}
[[ "$MESSAGE" != *'\n'* ]] || {
    echo "FAIL: message contains a literal newline escape" >&2
    exit 1
}
[[ "$MESSAGE" == *"$EXPECTED"* ]] || {
    echo "FAIL: message lost the eight-field record" >&2
    exit 1
}

cat > "${TEST_DIR}/fake-jq" <<'EOF'
#!/bin/bash
while [ "$#" -gt 0 ]; do
    if [ "$1" == "--arg" ] && [ "${2:-}" == "txt" ]; then
        printf '%s' "${3:-}" > "$MESSAGE_CAPTURE"
        shift 3
        continue
    fi
    shift
done
printf '{}\n'
EOF

cat > "${TEST_DIR}/fake-curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$CURL_CAPTURE"
printf '{"ok":true}\n'
EOF

chmod +x "${TEST_DIR}/fake-jq" "${TEST_DIR}/fake-curl"
export MESSAGE_CAPTURE="${TEST_DIR}/message.txt"
export CURL_CAPTURE="${TEST_DIR}/curl.txt"
CURL_BIN="${TEST_DIR}/fake-curl"
JQ_BIN="${TEST_DIR}/fake-jq"
send_registration_message "$MESSAGE" || {
    echo "FAIL: mocked message send failed" >&2
    exit 1
}
[ "$(cat "$MESSAGE_CAPTURE")" == "$MESSAGE" ] || {
    echo "FAIL: send path changed the message" >&2
    exit 1
}
grep -q -- '-X POST https://api.telegram.org/botTEST/sendMessage' "$CURL_CAPTURE" || {
    echo "FAIL: send path used the wrong endpoint" >&2
    exit 1
}

if (load_registration_config "${TEST_DIR}/missing-token.conf" >/dev/null 2>&1); then
    echo "FAIL: config without AGENT_TOKEN accepted" >&2
    exit 1
fi

if (load_registration_config "${TEST_DIR}/missing.conf" >/dev/null 2>&1); then
    echo "FAIL: missing config accepted" >&2
    exit 1
fi

echo "PASS: resend registration"
