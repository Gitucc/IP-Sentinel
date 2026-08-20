#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

INSTALL_ROOT="${TEST_DIR}/install"
mkdir -p "${INSTALL_ROOT}/core" "${INSTALL_ROOT}/data/keywords" "${INSTALL_ROOT}/data/regions/US/CA" "${INSTALL_ROOT}/logs"

cat > "${INSTALL_ROOT}/config.conf" <<EOF
AGENT_VERSION="test"
REGION_CODE="US"
LOG_FILE="${INSTALL_ROOT}/logs/sentinel.log"
IP_PREF="4"
BIND_IP=""
EOF

printf 'old keyword\n' > "${INSTALL_ROOT}/data/keywords/kw_US.txt"
printf '%s\n' "$(date +%s)" > "${INSTALL_ROOT}/core/.ua_last_update"

cat > "${INSTALL_ROOT}/data/regions/US/CA/Test.json" <<'EOF'
{
  "region_name": "Old",
  "google_module": {"base_lat": 1, "base_lon": 1, "lang_params": "hl=en-US&gl=US", "valid_url_suffix": "com"},
  "trust_module": {"white_urls": ["https://old.example"], "static_urls": ["https://old.example"]}
}
EOF

cat > "${TEST_DIR}/keywords.txt" <<'EOF'
current one
current two
current three
current four
current five
current six
EOF

cat > "${TEST_DIR}/region.json" <<'EOF'
{
  "region_name": "Updated",
  "google_module": {"base_lat": 1, "base_lon": 1, "lang_params": "hl=en-US&gl=US", "valid_url_suffix": "com"},
  "trust_module": {"white_urls": ["https://new.example"], "static_urls": ["https://new.example"]}
}
EOF

cat > "${TEST_DIR}/probe.sh" <<'EOF'
#!/bin/bash
# xykt/IPQuality test fixture
EOF

cat > "${TEST_DIR}/fake-curl" <<'EOF'
#!/bin/bash
source_url=""
destination_file=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        http*) source_url="$1" ;;
        -o)
            shift
            destination_file="$1"
            ;;
    esac
    shift
done

case "$source_url" in
    */data/keywords/kw_US.txt)
        if [ "${FAKE_BAD_KEYWORDS:-false}" == "true" ]; then
            printf '<html>error</html>\n' > "$destination_file"
        else
            cp "$KEYWORD_FIXTURE" "$destination_file"
        fi
        ;;
    */data/regions/US/CA/Test.json)
        cp "$REGION_FIXTURE" "$destination_file"
        ;;
    *xykt/IPQuality*)
        cp "$PROBE_FIXTURE" "$destination_file"
        ;;
    *)
        exit 22
        ;;
esac
EOF

chmod +x "${TEST_DIR}/fake-curl"
export KEYWORD_FIXTURE="${TEST_DIR}/keywords.txt"
export REGION_FIXTURE="${TEST_DIR}/region.json"
export PROBE_FIXTURE="${TEST_DIR}/probe.sh"

INSTALL_DIR="$INSTALL_ROOT" \
CONFIG_FILE="${INSTALL_ROOT}/config.conf" \
UA_TIME_FILE="${INSTALL_ROOT}/core/.ua_last_update" \
REPO_RAW_URL="https://example.invalid/repository" \
CURL_BIN="${TEST_DIR}/fake-curl" \
bash "${REPO_ROOT}/core/updater.sh" >/dev/null

cmp -s "${INSTALL_ROOT}/data/keywords/kw_US.txt" "${TEST_DIR}/keywords.txt" || {
    echo "FAIL: daily keyword file was not replaced" >&2
    exit 1
}
grep -q '"region_name": "Updated"' "${INSTALL_ROOT}/data/regions/US/CA/Test.json" || {
    echo "FAIL: region data was not replaced" >&2
    exit 1
}
grep -q 'xykt/IPQuality' "${INSTALL_ROOT}/core/ip_probe.sh" || {
    echo "FAIL: probe file was not replaced" >&2
    exit 1
}

cp "${TEST_DIR}/keywords.txt" "${INSTALL_ROOT}/data/keywords/kw_US.txt"
FAKE_BAD_KEYWORDS="true" \
INSTALL_DIR="$INSTALL_ROOT" \
CONFIG_FILE="${INSTALL_ROOT}/config.conf" \
UA_TIME_FILE="${INSTALL_ROOT}/core/.ua_last_update" \
REPO_RAW_URL="https://example.invalid/repository" \
CURL_BIN="${TEST_DIR}/fake-curl" \
bash "${REPO_ROOT}/core/updater.sh" >/dev/null

cmp -s "${INSTALL_ROOT}/data/keywords/kw_US.txt" "${TEST_DIR}/keywords.txt" || {
    echo "FAIL: invalid keyword response replaced the local file" >&2
    exit 1
}

echo "PASS: daily updater"
