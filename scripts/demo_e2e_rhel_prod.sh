#!/usr/bin/env bash
#
# demo_e2e_rhel_prod.sh — Typewriter talk track for the PROD VM (192.168.64.5).
#
# Run ON rhel-prod, not on the Mac. Do not git clone this repo onto prod.
# Demo app is Spring Boot shopapi.
#
#   bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part app
#   bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part rpms
#   bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part soak
#   bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part soak-avc
#   bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part fail
#   bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part restore
#   bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part retest
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/lib/e2e_demo.sh" ]]; then
    # shellcheck source=lib/training_lab_runner.sh
    source "${SCRIPT_DIR}/lib/training_lab_runner.sh"
    # shellcheck source=lib/e2e_demo.sh
    source "${SCRIPT_DIR}/lib/e2e_demo.sh"
elif [[ -f "${HOME}/e2e-demo/lib/e2e_demo.sh" ]]; then
    # shellcheck source=lib/training_lab_runner.sh
    source "${HOME}/e2e-demo/lib/training_lab_runner.sh"
    # shellcheck source=lib/e2e_demo.sh
    source "${HOME}/e2e-demo/lib/e2e_demo.sh"
    SCRIPT_DIR="${HOME}/e2e-demo/scripts"
    if [[ ! -d "${SCRIPT_DIR}" ]]; then
        SCRIPT_DIR="${HOME}/e2e-demo"
    fi
else
    echo "Cannot find lib/e2e_demo.sh. From the Mac, finish the shopapi scp, then re-run." >&2
    exit 1
fi

TLAB_PS1='[ansible@rhel-prod ~]$'
APP_BUNDLE="${HOME}/e2e-demo"
AVC_EXPORT="/tmp/prod-feature-spool.avc"
SOAK_FAIL_AVC="/var/lib/shopapi/selinux_soak_last_fail.avc"
SOAK_FAIL_JSON="/var/lib/shopapi/selinux_soak_last_fail.json"
SHOP_PORT="${SHOPAPI_PORT:-8091}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Presenter script for the PROD VM (${PROD_HOST}). Do not run this on the Mac.
Do not git clone onto this box — shopapi files from scp, policy from RPMs.
This is one window of the ~45 min three-host walkthrough (see demo_e2e_mac.sh).

  --part app      Install shopapi only (no SELinux module, unconfined JVM)
  --part rpms     Install selinux-policy-ops + shopapi-selinux from ~/
  --part soak     Canary soak: first-ship URLs 200, no shopapi AVC since canary
  --part soak-avc Confirm soak_monitor did not write a fail AVC file
  --part fail     curl /feature-spool (expect 500) and export AVCs
  --part restore  After emergency rollback: app 200 again (not a policy fix)
  --part retest   curl /feature-spool (expect 200) after recanary
  --part all      rpms (legacy default)

$(e2e_usage_common)
EOF
}

e2e_parse_args "$@"
e2e_require_rhel "the PROD VM (${PROD_HOST})"

part_app() {
    e2e_banner "PROD VM — install shopapi (no git, no policy module)"
    tlab_why "The JVM must be running here before we ship SELinux RPMs. We copy files from the Mac. We do not clone selinux-pac."
    e2e_run "hostname"
    e2e_ensure_hostname rhel-prod
    e2e_sync_clock
    e2e_run "test ! -d ${HOME}/selinux-pac && echo 'Good: no git clone of selinux-pac in home' || echo 'Note: a checkout exists — we still install from ~/e2e-demo'"
    tlab_pause

    e2e_run "sudo dnf install -y java-17-openjdk-headless python3 python3-pyyaml policycoreutils policycoreutils-python-utils"
    tlab_pause

    if [[ ! -f "${APP_BUNDLE}/scripts/demo_bootstrap.sh" ]]; then
        echo "Missing ${APP_BUNDLE}/scripts/demo_bootstrap.sh. On the Mac, finish the scp, then re-run --part app." >&2
        exit 1
    fi
    tlab_explain "--shopapi-only --no-seed --unconfined: JVM + unit, no shopapi_t yet (java is unconfined until the RPM)."
    e2e_run "sudo bash ${APP_BUNDLE}/scripts/demo_bootstrap.sh --shopapi-only --no-seed --unconfined"
    e2e_run "getenforce"
    e2e_run "systemctl is-active shopapi.service"
    e2e_run "ps -o label=,comm= -C java | head"
    e2e_run "curl -sf http://127.0.0.1:${SHOP_PORT}/health"
    tlab_checkpoint "shopapi is up unconfined. Go back to the Mac. Policy is not installed yet."
}

part_rpms() {
    e2e_banner "PROD VM — pretend production (${PROD_HOST})"
    tlab_why "Real shops do not git clone policy onto prod. Helpers come from RPMs."
    e2e_run "hostname"
    tlab_pause

    e2e_run "sudo dnf install -y policycoreutils policycoreutils-python-utils setools-console audit"
    tlab_pause

    if compgen -G "${HOME}/selinux-policy-ops-*.rpm" >/dev/null && compgen -G "${HOME}/shopapi-selinux-*.rpm" >/dev/null; then
        newest_ops="$(ls -1 "${HOME}"/selinux-policy-ops-*.rpm | sort -V | tail -1)"
        newest_app="$(ls -1 "${HOME}"/shopapi-selinux-*.rpm | sort -V | tail -1)"
        e2e_run "sudo rpm -Uvh --force ${newest_ops} ${newest_app}"
    elif rpm -q selinux-policy-ops shopapi-selinux >/dev/null 2>&1; then
        tlab_explain "Both RPMs are already installed."
    else
        if [[ "${TLAB_AUTO}" -eq 1 ]]; then
            echo "RPMs are not in ${HOME} and not installed. On the Mac, finish packaging/build_rpms.sh and scp, then re-run --part rpms." >&2
            exit 1
        fi
        tlab_pause
        newest_ops="$(ls -1 "${HOME}"/selinux-policy-ops-*.rpm | sort -V | tail -1)"
        newest_app="$(ls -1 "${HOME}"/shopapi-selinux-*.rpm | sort -V | tail -1)"
        e2e_run "sudo rpm -Uvh --force ${newest_ops} ${newest_app}"
    fi

    tlab_explain "Types now exist. Switch the unit to SELinuxContext=shopapi_t and restart."
    if [[ -f "${APP_BUNDLE}/scripts/demo_bootstrap.sh" ]]; then
        e2e_run "sudo DEMO_SHOPAPI_CONFINED=1 bash ${APP_BUNDLE}/scripts/demo_bootstrap.sh --shopapi-only --no-seed"
    fi
    e2e_run "rpm -q selinux-policy-ops shopapi-selinux"
    e2e_run "getenforce"
    e2e_run "command -v ausearch; command -v sesearch"
    tlab_checkpoint "Both RPMs print a version. Enforcing. Go back to the Mac for canary."
}

part_soak() {
    e2e_banner "PROD VM — soak: shopapi is up, AVC file is clean"
    tlab_why "Canary left shopapi_t permissive. First-ship URLs are in the module we just shipped."
    e2e_run "sudo rm -f ${SOAK_FAIL_JSON} ${SOAK_FAIL_AVC}"
    tlab_explain "Curl /health /state /log only. Do not call /feature-spool yet."
    e2e_run "for path in /health /state /log; do echo \"=== GET \${path} ===\"; curl -sf \"http://127.0.0.1:${SHOP_PORT}\${path}\"; echo; done"
    e2e_run 'marker=$(sudo cat /var/lib/selinux-policy-ops/shopapi/selinux_canary_deployed_at 2>/dev/null || true); if [[ -n "${marker}" ]]; then ts=$(date -d "@${marker}" "+%m/%d/%Y %H:%M:%S" 2>/dev/null || date -r "${marker}" "+%m/%d/%Y %H:%M:%S"); echo "canary marker ${ts}"; sudo ausearch -m avc -ts "${ts}" 2>/dev/null | grep shopapi | tail -20 && echo "(unexpected shopapi AVC)" || echo "Good: no shopapi AVC since canary"; else sudo ausearch -m avc -ts recent 2>/dev/null | grep shopapi | tail -10 || echo "Good: no shopapi AVC in recent log"; fi'
    tlab_checkpoint "HTTP 200 on first-ship URLs and a clean AVC log. Go back to the Mac for soak_monitor."
}

part_soak_avc() {
    e2e_banner "PROD VM — soak AVC file (should not exist)"
    e2e_run "sudo test ! -f ${SOAK_FAIL_AVC} && sudo test ! -f ${SOAK_FAIL_JSON} && echo 'Good: no ${SOAK_FAIL_AVC}' || sudo ls -l ${SOAK_FAIL_JSON} ${SOAK_FAIL_AVC}"
    tlab_checkpoint "No fail AVC file. Soak is clean. Go back to the Mac — we treat soak as complete and enforce."
}

part_fail() {
    e2e_banner "PROD VM — the new feature is denied after enforce"
    tlab_why "Policy is live. /feature-spool writes /var/spool/shopapi/feature.log — not in the first module. We will not semodule -i on this box."
    e2e_run_expect_fail "curl -sf http://127.0.0.1:${SHOP_PORT}/feature-spool"
    e2e_run "curl -sS http://127.0.0.1:${SHOP_PORT}/feature-spool || true"
    e2e_shopapi_avcs '|var_spool_t|/var/spool/shopapi'
    e2e_run "sudo grep 'avc:  denied' /var/log/audit/audit.log | grep shopapi_t | grep -E 'var_spool_t|/var/spool/shopapi' | tail -20 | tee ${AVC_EXPORT} >/dev/null; sudo chmod a+r ${AVC_EXPORT}; wc -l ${AVC_EXPORT}"
    tlab_checkpoint "HTTP 500 + an AVC in ${AVC_EXPORT}. Go back to the Mac — admin rollback, then generate on rhel-qa."
}

part_restore() {
    e2e_banner "PROD VM — admin restore (domain permissive again)"
    tlab_why "emergency_rollback.yml puts shopapi_t back to permissive. Host getenforce stays Enforcing."
    e2e_run "getenforce"
    e2e_run "systemctl is-active shopapi.service"
    e2e_run "curl -sf http://127.0.0.1:${SHOP_PORT}/health && echo 'HTTP 200 /health'"
    e2e_run "curl -sf http://127.0.0.1:${SHOP_PORT}/feature-spool | head -c 120; echo"
    tlab_checkpoint "Host is still Enforcing. App is up. Policy is not fixed."
}

part_retest() {
    e2e_banner "PROD VM — the fix arrived as a new RPM"
    e2e_run "curl -sf http://127.0.0.1:${SHOP_PORT}/feature-spool"
    tlab_checkpoint "HTTP 200 under the new module (enforcing)."
}

case "${E2E_PART}" in
    app) part_app ;;
    rpms|all) part_rpms ;;
    soak) part_soak ;;
    soak-avc) part_soak_avc ;;
    fail) part_fail ;;
    restore) part_restore ;;
    retest) part_retest ;;
    *)
        echo "Unknown --part ${E2E_PART} (use app, rpms, soak, soak-avc, fail, restore, retest)" >&2
        exit 2
        ;;
esac

echo
echo -e "${TLAB_BOLD}End of this PROD talk-track part.${TLAB_NC} Playbooks run on the Mac, not here."
echo
