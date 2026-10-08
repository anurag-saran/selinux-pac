#!/usr/bin/env bash
#
# demo_e2e_rhel_qa.sh — Typewriter talk track for the QA VM ($QA_HOST).
#
# Run ON rhel-qa, not on the Mac. Demo app is Spring Boot shopapi.
# This is one window of the ~45 min three-host walkthrough (see demo_e2e_mac.sh).
# Single-host customer talk (~20 min): bash scripts/demo_present.sh
#
# Legacy filename demo_e2e_rhel_dev.sh still execs this file (remove after 2026-12-31).
#
#   bash scripts/demo_e2e_rhel_qa.sh --part app
#   bash scripts/demo_e2e_rhel_qa.sh --part generate
#   bash scripts/demo_e2e_rhel_qa.sh --part generate --skip-export
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/lib/e2e_demo.sh" ]]; then
    # shellcheck source=lib/training_lab_runner.sh
    source "${SCRIPT_DIR}/lib/training_lab_runner.sh"
    # shellcheck source=lib/e2e_demo.sh
    source "${SCRIPT_DIR}/lib/e2e_demo.sh"
    # shellcheck source=lib/demo_estate.sh
    source "${SCRIPT_DIR}/lib/demo_estate.sh"
elif [[ -f "${HOME}/selinux-pac/scripts/lib/e2e_demo.sh" ]]; then
    # shellcheck source=lib/training_lab_runner.sh
    source "${HOME}/selinux-pac/scripts/lib/training_lab_runner.sh"
    # shellcheck source=lib/e2e_demo.sh
    source "${HOME}/selinux-pac/scripts/lib/e2e_demo.sh"
    # shellcheck source=lib/demo_estate.sh
    source "${HOME}/selinux-pac/scripts/lib/demo_estate.sh"
    SCRIPT_DIR="${HOME}/selinux-pac/scripts"
else
    echo "Cannot find scripts/lib/e2e_demo.sh. On this VM: cd ~/selinux-pac && git pull" >&2
    exit 1
fi

PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TLAB_PS1='[ansible@rhel-qa selinux-pac]$'
REPO_URL="${REPO_URL:-https://github.com/anurag-saran/selinux-pac.git}"
APP_ROOT="${APP_ROOT:-${HOME}/selinux-pac}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Presenter script for the QA VM (${DEV_HOST:-QA_HOST}). Do not run this on the Mac.
Demo application is shopapi (Spring Boot).

  --part app              shopapi + types-only seed + first-ship curls
  --part generate         ausearch (or --skip-export) → policy
  --part all              app, then pause, then generate
  --skip-export           With --part generate: use policy_out/avc.log from prod

$(e2e_usage_common)
EOF
}

e2e_parse_args "$@"
e2e_require_rhel "the QA VM (${DEV_HOST})"

shop_port() {
    demo_manifest_http_port "${APP_ROOT}/config/shopapi.manifest.yml"
}

first_ship_cmd() {
    local port
    port="$(shop_port)"
    echo "for path in /health /state /log; do echo \"=== GET \${path} ===\"; curl -sf \"http://127.0.0.1:${port}\${path}\"; echo; done"
}

part_app() {
    e2e_banner "QA VM — discovery box (${DEV_HOST})"
    tlab_why "SELinux runs HERE. The Mac is only the remote control. If the prompt does not say rhel-qa, stop."
    e2e_run "hostname"
    e2e_run "whoami"
    e2e_ensure_hostname rhel-qa
    e2e_sync_clock
    tlab_pause

    tlab_print_section "Part 2 — Spring Boot shopapi"
    tlab_explain "git, Java, Maven, ausearch, sesearch, semanage."
    e2e_run "sudo dnf install -y git java-17-openjdk-headless maven policycoreutils policycoreutils-python-utils setools-console audit selinux-policy-devel"
    tlab_pause

    if [[ -d "${HOME}/selinux-demo" && ! -d "${HOME}/selinux-pac" ]]; then
        e2e_run "mv ${HOME}/selinux-demo ${HOME}/selinux-pac"
    fi
    if [[ -d "${HOME}/selinux-pac" ]]; then
        tlab_explain "The tool (including demo/shopapi and selinux/shopapi) is already on this VM."
        e2e_run "ls ${HOME}/selinux-pac/scripts/dev_generate_policy.sh ${HOME}/selinux-pac/config/shopapi.manifest.yml"
    else
        e2e_run "git clone ${REPO_URL} ${HOME}/selinux-pac"
    fi
    tlab_pause

    tlab_explain "cd ~/selinux-pac. Policy we generate is selinux/shopapi/ in this repo."
    e2e_run "cd ${HOME}/selinux-pac && pwd && ls demo/shopapi/pom.xml selinux/shopapi/shopapi.te"
    tlab_pause

    tlab_explain "--shopapi-only installs the system JVM, the shopapi_exec_t wrapper at /opt/shopapi/bin/shopapi, and the types-only seed. No SELinuxContext= line: init_daemon_domain transitions from init_t. Permissive shopapi_t logs denials without blocking. Do not curl /feature-spool yet."
    e2e_run "sudo bash scripts/demo_bootstrap.sh --shopapi-only"
    tlab_pause

    e2e_run "getenforce"
    e2e_run "systemctl is-active shopapi.service"
    e2e_run "ps -o label=,comm= -C java | head"
    tlab_pause

    tlab_explain "First-ship URLs: /health /state /log. Not /feature-spool — that is the outage on prod."
    e2e_run "$(first_ship_cmd)"
    tlab_pause

    tlab_explain "These shopapi_t AVC lines are the input to generate."
    e2e_shopapi_avcs
    tlab_checkpoint "Enforcing; process is shopapi_t; first-ship curls produced AVCs. Go back to the Mac — next is generate."
}

part_generate() {
    e2e_banner "QA VM — turn denials into shopapi.te"
    cd "${HOME}/selinux-pac"
    if [[ "${E2E_SKIP_EXPORT}" -eq 1 ]]; then
        tlab_why "Prod captured the /feature-spool denial. We do not generate on prod."
        e2e_run "ls -l ${APP_ROOT}/policy_out/avc.log; wc -l ${APP_ROOT}/policy_out/avc.log"
        tlab_pause
        e2e_run "sudo bash scripts/dev_generate_policy.sh --skip-export --apply --allow-needs-review --app-name shopapi --app-root ${APP_ROOT}"
    else
        tlab_why "shopapi_t is permissive. First-ship curls logged denials. --apply writes allows into selinux/shopapi/. --allow-needs-review is only because this JVM log includes execmem — we do not invent it."
        e2e_run "sudo restorecon -Rv /opt/shopapi /var/lib/shopapi /var/log/shopapi /run/shopapi"
        tlab_pause
        e2e_run "sudo bash scripts/dev_generate_policy.sh --apply --allow-needs-review --app-name shopapi --app-root ${APP_ROOT}"
    fi
    e2e_run "POLICY_MODULE=shopapi SELINUX_DOMAIN=shopapi_t bash scripts/compile_and_validate.sh ${APP_ROOT}/selinux/shopapi"
    e2e_run "sudo semodule -i ${APP_ROOT}/selinux/shopapi/shopapi.pp"
    e2e_run "sudo semanage port -a -t shopapi_port_t -p tcp $(shop_port) 2>/dev/null || sudo semanage port -m -t shopapi_port_t -p tcp $(shop_port)"
    tlab_pause
    e2e_explain_selinux_tree "${APP_ROOT}"
    e2e_run "ls -l ${APP_ROOT}/selinux/shopapi/shopapi.te ${APP_ROOT}/selinux/shopapi/shopapi.fc ${APP_ROOT}/selinux/shopapi/policy_version.txt ${APP_ROOT}/selinux/shopapi/shopapi.pp"
    e2e_run "echo '--- generated shopapi.te (head) ---'; head -30 ${APP_ROOT}/selinux/shopapi/shopapi.te"
    tlab_checkpoint "selinux/shopapi/shopapi.te is generated from AVCs. Go back to the Mac: copy sources, open a GitHub PR on selinux-pac, then canary."
}

case "${E2E_PART}" in
    app) part_app ;;
    generate) part_generate ;;
    fail)
        echo "Fail/retest runs on rhel-prod, not here:" >&2
        echo "  bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part fail" >&2
        exit 2
        ;;
    all)
        part_app
        e2e_handoff "Leave this window open. On the Mac, do not canary yet. Come back here for --part generate.
Press Enter when you are ready to generate."
        part_generate
        ;;
    *)
        echo "Unknown --part ${E2E_PART} (use app, generate, or all)" >&2
        exit 2
        ;;
esac

echo
echo -e "${TLAB_BOLD}End of this QA talk-track part.${TLAB_NC} Do not type exit until the Mac script asks you to."
echo
