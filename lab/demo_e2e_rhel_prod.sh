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
    # shellcheck source=lib/present.sh
    source "${SCRIPT_DIR}/lib/present.sh"
elif [[ -f "${HOME}/e2e-demo/lib/e2e_demo.sh" ]]; then
    # shellcheck source=lib/training_lab_runner.sh
    source "${HOME}/e2e-demo/lib/training_lab_runner.sh"
    # shellcheck source=lib/e2e_demo.sh
    source "${HOME}/e2e-demo/lib/e2e_demo.sh"
    # shellcheck source=lib/present.sh
    source "${HOME}/e2e-demo/lib/present.sh"
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

  --part app        Install shopapi only (no SELinux module, unconfined JVM)
  --part rpms       Show dnf repo and GPG key (policy arrives from canary)
  --part soak       Canary soak: curl /feature-spool, denial in audit log
  --part soak-avc   Confirm soak_monitor wrote the fail file
  --part soak-clean After the fix: /feature-spool 200, no new denial
  --part fail       curl /feature-spool (expect 500) and export AVCs
  --part restore    After emergency rollback: app 200 again
  --part retest     curl /feature-spool (expect 200) after recanary

$(e2e_usage_common)
EOF
}

e2e_parse_args "$@"
e2e_require_rhel "the PROD VM (${PROD_HOST})"

part_app() {
    e2e_banner "PROD VM — install shopapi (no git, no policy module)"
    say "Set the hostname"
    present_cmd "sudo hostnamectl set-hostname rhel-prod && hostname"
    if [[ "${E2E_DRY}" -eq 0 ]]; then
        sudo timedatectl set-ntp true 2>/dev/null || true
        sudo chronyc makestep 2>/dev/null || true
    fi
    tlab_pause

    say "Java and SELinux tools"
    present_cmd "sudo dnf install -y java-17-openjdk-headless python3 python3-pyyaml policycoreutils policycoreutils-python-utils"
    tlab_pause

    if [[ ! -f "${APP_BUNDLE}/lab/demo_bootstrap.sh" ]]; then
        echo "Missing ${APP_BUNDLE}/lab/demo_bootstrap.sh. On the Mac, finish the scp, then re-run --part app." >&2
        exit 1
    fi
    say "JVM + unit, no shopapi_t yet (unconfined until the RPM)"
    present_cmd "sudo bash ${APP_BUNDLE}/lab/demo_bootstrap.sh --shopapi-only --no-seed --unconfined"
    say "shopapi is up unconfined"
    present_cmd "sepac status shopapi && curl -sf http://127.0.0.1:${SHOP_PORT}/health && echo ' /health 200'"
    tlab_checkpoint "shopapi is up. Policy is not installed yet. Go back to the Mac."
}

part_rpms() {
    e2e_banner "PROD VM — policy arrives from the canary, not from a hand-installed RPM"
    say "Policy tools for the soak monitor"
    present_cmd "sudo dnf install -y policycoreutils policycoreutils-python-utils setools-console audit"
    say "Repo is configured with gpgcheck=1; key is imported"
    present_cmd "sudo dnf repolist && rpm -q gpg-pubkey && sepac status shopapi"
    tlab_checkpoint "The process is still unconfined. Go back to the Mac for deploy_canary.yml."
}

part_soak() {
    e2e_banner "PROD VM — soak: /feature-spool is not in this module"
    say "Curl all URLs — permissive lets the spool write succeed, but the denial is logged"
    present_cmd "for path in /health /state /log /feature-spool; do echo \"=== GET \${path} ===\"; curl -sS -o /dev/null -w \"%{http_code}\\n\" \"http://127.0.0.1:${SHOP_PORT}\${path}\" || true; done"
    say "The spool denial that fails the soak gate"
    present_cmd "sepac denials shopapi --since boot --last 20 && sudo grep 'avc:  denied' /var/log/audit/audit.log | grep shopapi_t | grep -E 'var_spool_t|/var/spool/shopapi' | tail -20 | tee ${AVC_EXPORT} >/dev/null && sudo chmod a+r ${AVC_EXPORT} && wc -l ${AVC_EXPORT}"
    tlab_checkpoint "A shopapi denial for /var/spool/shopapi is in ${AVC_EXPORT}. Go back to the Mac."
}

part_soak_avc() {
    e2e_banner "PROD VM — soak monitor wrote the fail file"
    present_cmd "sudo ls -l ${SOAK_FAIL_JSON} ${SOAK_FAIL_AVC}"
    tlab_checkpoint "The fail file is there. Go back to the Mac."
}

part_soak_clean() {
    e2e_banner "PROD VM — clean soak after the spool allow"
    say "All four URLs return 200 with the new module"
    present_cmd "for path in /health /state /log /feature-spool; do echo \"=== GET \${path} ===\"; curl -sf \"http://127.0.0.1:${SHOP_PORT}\${path}\" >/dev/null && echo 200; done"
    say "No new shopapi denial since this canary"
    present_cmd "sepac denials shopapi --since boot --last 20"
    tlab_checkpoint "HTTP 200 and clean AVC log. Go back to the Mac."
}

part_fail() {
    e2e_banner "PROD VM — the new feature is denied after enforce"
    say "/feature-spool writes /var/spool/shopapi — not in the first module"
    present_cmd "curl -sf http://127.0.0.1:${SHOP_PORT}/feature-spool" fail
    say "The denial and the AVC export for rhel-qa"
    present_cmd "sepac denials shopapi --since boot --last 20 && sudo grep 'avc:  denied' /var/log/audit/audit.log | grep shopapi_t | grep -E 'var_spool_t|/var/spool/shopapi' | tail -20 | tee ${AVC_EXPORT} >/dev/null && sudo chmod a+r ${AVC_EXPORT} && wc -l ${AVC_EXPORT}"
    tlab_checkpoint "HTTP 500 + AVC in ${AVC_EXPORT}. Go back to the Mac — rollback, then generate on rhel-qa."
}

part_restore() {
    e2e_banner "PROD VM — admin restore (domain permissive again)"
    say "Host is Enforcing, app is up, policy is not fixed"
    present_cmd "sepac status shopapi && curl -sf http://127.0.0.1:${SHOP_PORT}/health && echo ' /health 200' && curl -sf http://127.0.0.1:${SHOP_PORT}/feature-spool | head -c 120; echo"
    tlab_checkpoint "Host is still Enforcing. App is up. Policy is not fixed."
}

part_retest() {
    e2e_banner "PROD VM — the fix arrived as a new RPM"
    say "HTTP 200 under the new module (enforcing)"
    present_cmd "curl -sf http://127.0.0.1:${SHOP_PORT}/feature-spool && sepac status shopapi"
    tlab_checkpoint "shopapi_t enforcing."
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
