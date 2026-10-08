#!/usr/bin/env bash
#
# demo_e2e_rhel_prod.sh — Typewriter talk track for the PROD VM ($PROD_HOST).
#
# Run ON rhel-prod, not on the Mac. Do not git clone this repo onto prod.
# Demo app is Spring Boot shopapi.
#
#   bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part app
#   bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part rpms
#   bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part soak
#   bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part soak-avc
#   bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part soak-clean
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
SOAK_FAIL_AVC="/var/lib/selinux-policy-ops/shopapi/selinux_soak_last_fail.avc"
SOAK_FAIL_JSON="/var/lib/selinux-policy-ops/shopapi/selinux_soak_last_fail.json"
SHOP_PORT="${SHOPAPI_PORT:-8091}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Presenter script for the PROD VM (${PROD_HOST:-PROD_HOST}). Do not run this on the Mac.
Do not git clone onto this box — shopapi files from scp, policy from RPMs.
This is one window of the ~45 min three-host walkthrough (see demo_e2e_mac.sh).

  --part app      Install shopapi only (no SELinux module, unconfined JVM)
  --part rpms     Install selinux-policy-ops + shopapi-selinux from ~/
  --part soak      Canary soak: curl /feature-spool, denial is in the audit log
  --part soak-avc  Confirm soak_monitor wrote the fail file
  --part soak-clean  After the fix: /feature-spool returns 200 and no new denial
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
    e2e_banner "PROD VM — policy arrives from the canary, not from a hand-installed RPM (${PROD_HOST})"
    tlab_why "The dnf repo has gpgcheck=1. deploy_canary.yml installs the RPMs and sets shopapi_t permissive before it restarts the service. This window does not start the service in the new domain."
    e2e_run "hostname"
    tlab_pause
    e2e_run "sudo dnf install -y policycoreutils policycoreutils-python-utils setools-console audit"
    tlab_explain "Leave the JVM unconfined until the Mac runs deploy_canary.yml. Do not install the RPM files by hand and do not restart shopapi here."
    e2e_run "sudo dnf repolist"
    e2e_run "rpm -q gpg-pubkey"
    e2e_run "getenforce"
    e2e_run "systemctl is-active shopapi.service"
    e2e_run "ps -o label=,comm= -C java | head"
    tlab_checkpoint "The process is still unconfined. Go back to the Mac for deploy_canary.yml."
}

part_soak() {
    e2e_banner "PROD VM — soak: /feature-spool is not in this module"
    tlab_why "Canary left shopapi_t permissive, so the request can still return 200. The denial is in the audit log. soak_monitor reads that log."
    tlab_explain "Curl /health /state /log, then /feature-spool. Fail files already in /var/lib/selinux-policy-ops/shopapi/ stay there. This canary's marker is what the monitor counts."
    e2e_run "for path in /health /state /log /feature-spool; do echo \"=== GET \${path} ===\"; curl -sS -o /dev/null -w \"%{http_code}\\n\" \"http://127.0.0.1:${SHOP_PORT}\${path}\" || true; done"
    e2e_run 'marker=$(sudo cat /var/lib/selinux-policy-ops/shopapi/selinux_canary_deployed_at 2>/dev/null || true); if [[ "${marker}" =~ ^[0-9]+$ ]]; then echo "canary marker epoch ${marker}"; sudo ausearch -m avc --format raw 2>/dev/null | while IFS= read -r line; do epoch="${line#*msg=audit(}"; epoch="${epoch%%.*}"; [[ "${epoch}" =~ ^[0-9]+$ && "${epoch}" -ge "${marker}" ]] && printf "%s\n" "${line}"; done | grep shopapi | tail -20 || echo "No shopapi AVC since canary"; else sudo ausearch -m avc -ts recent 2>/dev/null | grep shopapi | tail -10 || echo "No shopapi AVC in recent log"; fi'
    e2e_run "sudo grep 'avc:  denied' /var/log/audit/audit.log | grep shopapi_t | grep -E 'var_spool_t|/var/spool/shopapi' | tail -20 | tee ${AVC_EXPORT} >/dev/null; sudo chmod a+r ${AVC_EXPORT}; wc -l ${AVC_EXPORT}"
    tlab_checkpoint "A shopapi denial for /var/spool/shopapi is in ${AVC_EXPORT}. Go back to the Mac. soak_monitor must fail."
}

part_soak_avc() {
    e2e_banner "PROD VM — soak monitor wrote the fail file"
    e2e_run "sudo ls -l ${SOAK_FAIL_JSON} ${SOAK_FAIL_AVC}"
    tlab_checkpoint "The fail file is there. Go back to the Mac. Enforce without force_enforce must refuse."
}

part_soak_clean() {
    e2e_banner "PROD VM — clean soak after the spool allow"
    tlab_why "The new module allows /var/spool/shopapi. shopapi_t is still permissive until enforce."
    tlab_explain "Curl /health /state /log /feature-spool. Each should be HTTP 200, and ausearch should show no new shopapi denial since this canary. Older fail files stay on disk."
    e2e_run "for path in /health /state /log /feature-spool; do echo \"=== GET \${path} ===\"; curl -sf \"http://127.0.0.1:${SHOP_PORT}\${path}\" >/dev/null && echo 200; done"
    e2e_run 'marker=$(sudo cat /var/lib/selinux-policy-ops/shopapi/selinux_canary_deployed_at 2>/dev/null || true); if [[ "${marker}" =~ ^[0-9]+$ ]]; then echo "canary marker epoch ${marker}"; sudo ausearch -m avc --format raw 2>/dev/null | while IFS= read -r line; do epoch="${line#*msg=audit(}"; epoch="${epoch%%.*}"; [[ "${epoch}" =~ ^[0-9]+$ && "${epoch}" -ge "${marker}" ]] && printf "%s\n" "${line}"; done | grep shopapi | tail -20 && echo "(unexpected shopapi AVC)" || echo "Good: no shopapi AVC since canary"; else sudo ausearch -m avc -ts recent 2>/dev/null | grep shopapi | tail -10 || echo "Good: no shopapi AVC in recent log"; fi'
    tlab_checkpoint "HTTP 200 including /feature-spool, and a clean AVC log. Go back to the Mac. soak_monitor should pass."
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
    soak-clean) part_soak_clean ;;
    fail) part_fail ;;
    restore) part_restore ;;
    retest) part_retest ;;
    *)
        echo "Unknown --part ${E2E_PART} (use app, rpms, soak, soak-avc, soak-clean, fail, restore, retest)" >&2
        exit 2
        ;;
esac

echo
echo -e "${TLAB_BOLD}End of this PROD talk-track part.${TLAB_NC} Playbooks run on the Mac, not here."
echo
