#!/bin/bash

is_public_agent_address() {
    local raw_addresses="$1"

    command -v python3 >/dev/null 2>&1 || return 1

    python3 - "$raw_addresses" <<'PY'
import ipaddress
import sys

raw_addresses = sys.argv[1].replace("_", ",")
addresses = [item.strip() for item in raw_addresses.split(",") if item.strip()]
if not addresses:
    raise SystemExit(1)

for value in addresses:
    if value.startswith("[") and value.endswith("]"):
        value = value[1:-1]
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        raise SystemExit(1)
    if not address.is_global or address.is_multicast or address.is_unspecified or address.is_reserved:
        raise SystemExit(1)
PY
}

is_valid_node_name() {
    [[ "$1" =~ ^[a-zA-Z0-9_.-]+$ ]]
}

is_valid_toggle_request() {
    local module_name="$1"
    local node_name="$2"
    local target_state="$3"

    [[ "$module_name" == "google" || "$module_name" == "trust" ]] || return 1
    is_valid_node_name "$node_name" || return 1
    [[ "$target_state" == "true" || "$target_state" == "false" ]]
}

is_callback_request() {
    [[ -n "$1" ]]
}

is_privileged_callback_payload() {
    case "$1" in
        all_run|all_reports|all_ota_confirm|all_ota_execute|master_ota_confirm|master_ota_execute)
            return 0
            ;;
        toggle:*|rename:*|del_confirm:*|del_execute:*|ota_confirm:*|ota_execute:*)
            return 0
            ;;
        google:*|trust:*|run:*|report:*|log:*|quality:*|trend:*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}
