#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
export INSTALL_DIR="${TEST_DIR}/install"
mkdir -p "${INSTALL_DIR}/core" "${INSTALL_DIR}/data/keywords" "${INSTALL_DIR}/data/regions" "${TEST_DIR}/bin"
cp "${REPO_ROOT}/core/updater.sh" "${INSTALL_DIR}/core/"
cat > "${INSTALL_DIR}/config.conf" <<EOF
AGENT_VERSION=test
REGION_CODE=US
LOG_FILE="${INSTALL_DIR}/sentinel.log"
BIND_IP=""
EOF

cat > "${TEST_DIR}/bin/date" <<'EOF'
#!/bin/bash
case "$*" in
    '-u +%F') echo "$TEST_DAY" ;;
    '-u +%H') echo "$TEST_HOUR" ;;
    '-u +%s'|'+%s') echo "$TEST_NOW" ;;
    *) /usr/bin/date "$@" ;;
esac
EOF
cat > "${TEST_DIR}/bin/flock" <<'EOF'
#!/bin/bash
[[ "$*" == '-n 9' ]] || exit 2
exit "${TEST_LOCK_RESULT:-0}"
EOF
cat > "${TEST_DIR}/bin/curl" <<'EOF'
#!/bin/bash
while [ "$#" -gt 0 ]; do
    case "$1" in
        http*) url="$1" ;;
        -o) shift; destination="$1" ;;
    esac
    shift
done
case "$url" in
    */updated_at)
        echo attempt >> "${INSTALL_DIR}/calls"
        [ "${TEST_UPDATE_RESULT:-0}" -eq 0 ] || exit 22
        printf '%s\n' "${TEST_PUBLICATION:-$TEST_DAY}" > "$destination"
        ;;
    */kw_US.txt) printf 'one\ntwo\nthree\nfour\nfive\n' > "$destination" ;;
    */ip.sh) printf '#!/bin/bash\n# xykt\n' > "$destination" ;;
    *) exit 22 ;;
esac
EOF
chmod +x "${TEST_DIR}/bin/"*
export PATH="${TEST_DIR}/bin:$PATH"
export TEST_DAY=2026-09-05 TEST_HOUR=09 TEST_NOW=1788598801
printf '%s\n' "$TEST_NOW" > "${INSTALL_DIR}/core/.ua_last_update"
run_update() { bash "${INSTALL_DIR}/core/updater.sh" --scheduled >/dev/null; }
calls() { wc -l < "${INSTALL_DIR}/calls"; }

run_update
[[ ! -f "${INSTALL_DIR}/calls" ]] || exit 1
export TEST_HOUR=10 TEST_UPDATE_RESULT=1
if run_update; then echo 'FAIL: update failure was hidden'; exit 1; fi
[[ $(calls) -eq 1 ]] || exit 1
[[ ! -f "${INSTALL_DIR}/data/.update_state/success" ]] || exit 1
run_update
[[ $(calls) -eq 1 ]] || exit 1
export TEST_NOW=$((TEST_NOW + 3599)) TEST_HOUR=11 TEST_UPDATE_RESULT=0
run_update
[[ $(calls) -eq 2 ]] || exit 1
[[ $(cat "${INSTALL_DIR}/data/.update_state/success") == "$TEST_DAY" ]] || exit 1
export TEST_NOW=$((TEST_NOW + 3600)) TEST_HOUR=12
run_update
[[ $(calls) -eq 2 ]] || exit 1
export TEST_DAY=2026-09-06 TEST_NOW=$((TEST_NOW + 86400)) TEST_HOUR=17
TEST_LOCK_RESULT=1 run_update
[[ $(calls) -eq 2 ]] || exit 1
run_update
[[ $(calls) -eq 3 ]] || exit 1

for publication in 2026-09-05 invalid 2026-09-07; do
    rm -f "${INSTALL_DIR}/data/.update_state/success" "${INSTALL_DIR}/data/.update_state/attempt"
    printf 'keep old keywords\n' > "${INSTALL_DIR}/data/keywords/kw_US.txt"
    if TEST_PUBLICATION="$publication" run_update; then
        echo "FAIL: accepted publication $publication"; exit 1
    fi
    grep -qx 'keep old keywords' "${INSTALL_DIR}/data/keywords/kw_US.txt"
    [[ ! -f "${INSTALL_DIR}/data/.update_state/success" ]]
done
export TEST_NOW=$((TEST_NOW + 3600))
run_update
grep -qx 'one' "${INSTALL_DIR}/data/keywords/kw_US.txt"
[[ $(cat "${INSTALL_DIR}/data/.update_state/success") == "$TEST_DAY" ]]

echo 'PASS: UTC window, hourly retry, daily deduplication, late start and lock contention'
echo 'PASS: missing, stale, invalid and future publication; recovery'
