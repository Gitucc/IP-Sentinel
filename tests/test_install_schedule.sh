#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
INSTALL_DIR="${TEST_DIR}/install"
SECURE_TMP="${TEST_DIR}/tmp"
TG_TOKEN='' CHAT_ID='' PUBLIC_IP=''
mkdir -p "${INSTALL_DIR}/core" "$SECURE_TMP" "${TEST_DIR}/etc/systemd/system" "${TEST_DIR}/etc/local.d"
is_systemd() { [[ "$TEST_BACKEND" == systemd ]]; }
systemctl() { printf '%s\n' "$*" >> "${TEST_DIR}/systemctl"; }
nohup() { :; }
pkill() { :; }
rc-update() { :; }
rc-service() { :; }
crontab() {
    if [[ "$1" == -l ]]; then
        echo '0 1 * * * /usr/local/bin/other-job'
        echo '0 2 * * * /opt/ip_sentinel/core/updater.sh'
    else
        cp "$1" "${TEST_DIR}/installed-cron"
    fi
}

for entry in install/sys_daemon.sh core/install.sh; do
    if [[ "$entry" == core/install.sh ]]; then
        {
            echo 'do_inject_daemon() {'
            sed -n '/^echo -e.*\[7\/7\]/,/^REG_MSG=/p' "${REPO_ROOT}/${entry}" | sed '$d'
            echo '}'
        } > "${TEST_DIR}/source.sh"
    else
        cp "${REPO_ROOT}/${entry}" "${TEST_DIR}/source.sh"
    fi
    sed -e "s|/etc/|${TEST_DIR}/etc/|g" -e "s|/var/spool/|${TEST_DIR}/var/spool/|g" \
        -e "s|/proc/|${TEST_DIR}/proc/|g" -e "s|/.dockerenv|${TEST_DIR}/.dockerenv|g" \
        "${TEST_DIR}/source.sh" > "${TEST_DIR}/isolated.sh"
    source "${TEST_DIR}/isolated.sh"
    TEST_BACKEND=systemd
    do_inject_daemon >/dev/null
    grep -qx 'OnCalendar=\*-\*-\* 10\.\.23:00:00 UTC' "${TEST_DIR}/etc/systemd/system/ip-sentinel-updater.timer"
    grep -qx "ExecStart=/bin/bash ${INSTALL_DIR}/core/updater.sh --scheduled" "${TEST_DIR}/etc/systemd/system/ip-sentinel-updater.service"
    TEST_BACKEND=cron
    do_inject_daemon >/dev/null
    grep -qx "0 \* \* \* \* /bin/bash ${INSTALL_DIR}/core/updater.sh --scheduled >/dev/null 2>&1" "${TEST_DIR}/installed-cron"
    grep -q '/usr/local/bin/other-job' "${TEST_DIR}/installed-cron"
    if grep -q '/core/updater.sh$' "${TEST_DIR}/installed-cron"; then exit 1; fi
    touch "${TEST_DIR}/etc/alpine-release" "${TEST_DIR}/.dockerenv"
    do_inject_daemon >/dev/null
    bash -n "${INSTALL_DIR}/core/sentinel_scheduler.sh"
    grep -q '/core/updater.sh --scheduled' "${INSTALL_DIR}/core/sentinel_scheduler.sh"
    rm "${TEST_DIR}/etc/alpine-release" "${TEST_DIR}/.dockerenv"
done
echo 'PASS: both installers generate systemd, Cron and Alpine schedules'
