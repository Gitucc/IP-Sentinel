#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
sed -n '/^send_ui() {/,/^log_master_event() {/p' "${REPO_ROOT}/master/tg_master.sh" | sed '$d' > "${TEST_DIR}/ui.sh"
source "${TEST_DIR}/ui.sh"
TG_TOKEN=test
EDIT_RESPONSE='{"ok":true}'
CURL_LOG="${TEST_DIR}/calls"
PAYLOAD_FILE="${TEST_DIR}/payload"
curl() {
    local url='' payload=''
    while [ "$#" -gt 0 ]; do
        case "$1" in
            https:*) url="$1" ;;
            -d) shift; payload="$1" ;;
        esac
        shift
    done
    echo "${url##*/}" >> "$CURL_LOG"
    printf '%s' "$payload" > "$PAYLOAD_FILE"
    if [[ "$url" == */editMessageText ]]; then
        printf '%s' "$EDIT_RESPONSE"
    else
        printf '{"ok":true}'
    fi
}

render_ui 100 7 'first\n"quoted"' '[[{"text":"back","callback_data":"/start"}]]'
[[ $(cat "$CURL_LOG") == editMessageText ]]
jq -e '.chat_id == "100" and .message_id == "7" and .text == "first\n\"quoted\"" and .reply_markup.inline_keyboard[0][0].callback_data == "/start"' "$PAYLOAD_FILE" >/dev/null

: > "$CURL_LOG"
render_ui 200 7 'another chat' '[]'
jq -e '.chat_id == "200" and .message_id == "7"' "$PAYLOAD_FILE" >/dev/null
[[ $(wc -l < "$CURL_LOG") -eq 1 ]]

: > "$CURL_LOG"
EDIT_RESPONSE='{"ok":false,"description":"Bad Request: message is not modified"}'
render_ui 100 7 'same panel' '[]'
[[ $(cat "$CURL_LOG") == editMessageText ]]

: > "$CURL_LOG"
EDIT_RESPONSE='{"ok":false,"description":"Bad Request: message to edit not found"}'
render_ui 100 7 'replacement' '[]'
[[ $(wc -l < "$CURL_LOG") -eq 2 ]]
[[ $(tail -n 1 "$CURL_LOG") == sendMessage ]]

: > "$CURL_LOG"
render_ui 300 '' 'new panel' '[]'
[[ $(cat "$CURL_LOG") == sendMessage ]]
jq -e '.chat_id == "300" and .text == "new panel"' "$PAYLOAD_FILE" >/dev/null
echo 'PASS: panel edits, chat isolation, unchanged content, fallback and JSON escaping'
