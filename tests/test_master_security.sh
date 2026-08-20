#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${REPO_ROOT}/master/security_policy.sh"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_denied_address() {
    if is_public_agent_address "$1"; then
        fail "address should be denied: $1"
    fi
}

assert_allowed_address() {
    is_public_agent_address "$1" || fail "address should be allowed: $1"
}

for address in \
    127.0.0.1 10.0.0.1 172.16.0.1 192.168.1.1 \
    169.254.169.254 100.64.0.1 ::1 fc00::1 fe80::1 ff02::1 \
    ::ffff:127.0.0.1 localhost agent.internal; do
    assert_denied_address "$address"
done

assert_allowed_address "1.1.1.1"
assert_allowed_address "8.8.8.8_[2606:4700:4700::1111]"

is_valid_toggle_request google node-1 true || fail "valid Google toggle rejected"
is_valid_toggle_request trust node_2 false || fail "valid Trust toggle rejected"
if is_valid_toggle_request "google, enable_ota='true'" node-1 true; then
    fail "invalid module accepted"
fi
if is_valid_toggle_request google "node';DROP TABLE nodes;--" true; then
    fail "invalid node accepted"
fi
if is_valid_toggle_request google node-1 enabled; then
    fail "invalid state accepted"
fi

is_callback_request callback-id || fail "callback id rejected"
if is_callback_request ""; then
    fail "empty callback id accepted"
fi

is_privileged_callback_payload "master_ota_execute" || fail "privileged command not classified"
is_privileged_callback_payload "toggle:google:node-1:true" || fail "toggle not classified"
if is_privileged_callback_payload "/start"; then
    fail "ordinary command classified as privileged"
fi

echo "PASS: master security policy"
