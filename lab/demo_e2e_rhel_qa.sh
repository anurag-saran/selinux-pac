#!/usr/bin/env bash
#
# demo_e2e_rhel_qa.sh — Typewriter talk track for the QA VM ($QA_HOST).
#
# Run ON rhel-qa, not on the Mac. Demo app is Spring Boot shopapi.
# This is one window of the ~45 min three-host walkthrough (see demo_e2e_mac.sh).
# Single-host customer talk (~20 min): bash lab/demo_present.sh
#
# Legacy filename demo_e2e_rhel_dev.sh still execs this file (remove after 2026-12-31).
#
#   bash lab/demo_e2e_rhel_qa.sh --part app
#   bash lab/demo_e2e_rhel_qa.sh --part generate
#   bash lab/demo_e2e_rhel_qa.sh --part generate --skip-export
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
    # shellcheck source=lib/present.sh
    source "${SCRIPT_DIR}/lib/present.sh"
elif [[ -f "${HOME}/selinux-pac/lab/lib/e2e_demo.sh" ]]; then
    # shellcheck source=lib/training_lab_runner.sh
    source "${HOME}/selinux-pac/lab/lib/training_lab_runner.sh"
    # shellcheck source=lib/e2e_demo.sh
    source "${HOME}/selinux-pac/lab/lib/e2e_demo.sh"
    # shellcheck source=lib/demo_estate.sh
    source "${HOME}/selinux-pac/lab/lib/demo_estate.sh"
    # shellcheck source=lib/present.sh
    source "${HOME}/selinux-pac/lab/lib/present.sh"
    SCRIPT_DIR="${HOME}/selinux-pac/lab"
else
    echo "Cannot find lab/lib/e2e_demo.sh. On this VM: cd ~/selinux-pac && git pull" >&2
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
  --all-urls              With --part app: also curl /feature-spool (happy-path 302)
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

all_urls_cmd() {
    local port
    port="$(shop_port)"
    echo "for path in /health /state /log /feature-spool; do echo \"=== GET \${path} ===\"; curl -sf \"http://127.0.0.1:${port}\${path}\"; echo; done"
}

part_app() {
    e2e_banner "QA VM — discovery box (${DEV_HOST})"
    say "Set the hostname so the prompt matches the talk track"
    present_cmd "sudo hostnamectl set-hostname rhel-qa && hostname"
    if [[ "${E2E_DRY}" -eq 0 ]]; then
        sudo timedatectl set-ntp true 2>/dev/null || true
        sudo chronyc makestep 2>/dev/null || true
    fi
    tlab_pause

    say "Install Java, Maven, and SELinux tools"
    present_cmd "sudo dnf install -y git java-17-openjdk-headless maven policycoreutils policycoreutils-python-utils setools-console audit selinux-policy-devel"
    tlab_pause

    if [[ -d "${HOME}/selinux-demo" && ! -d "${HOME}/selinux-pac" ]]; then
        mv "${HOME}/selinux-demo" "${HOME}/selinux-pac" 2>/dev/null || true
    fi
    if [[ ! -d "${HOME}/selinux-pac" ]]; then
        say "Clone the tool repo"
        present_cmd "git clone ${REPO_URL} ${HOME}/selinux-pac"
    fi
    say "The tool checkout with shopapi and the types-only seed"
    present_cmd "cd ${HOME}/selinux-pac && ls demo/shopapi/pom.xml selinux/shopapi/shopapi.te"
    tlab_pause

    say "Bootstrap shopapi: JVM, unit, types-only seed, permissive"
    present_cmd "sudo bash lab/demo_bootstrap.sh --shopapi-only"
    tlab_pause

    say "Host is Enforcing; the process label is shopapi_t"
    present_cmd "getenforce && systemctl is-active shopapi.service && ps -o label=,comm= -C java | head"
    tlab_pause

    say "Restart with dontaudit off so startup denials are visible"
    present_cmd "sudo semodule -DB && sudo systemctl restart shopapi.service && ok=0; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do if curl -sf http://127.0.0.1:$(shop_port)/health >/dev/null; then ok=1; break; fi; sleep 2; done; test \"\${ok}\" = 1"
    if [[ "${E2E_ALL_URLS}" -eq 1 ]]; then
        say "All URLs including /feature-spool, then restore dontaudit"
        present_cmd "$(all_urls_cmd) && sudo semodule -B"
    else
        say "First-ship URLs (not /feature-spool), then restore dontaudit"
        present_cmd "$(first_ship_cmd) && sudo semodule -B"
    fi
    if [[ "${E2E_DRY}" -eq 0 ]]; then
        trap - EXIT 2>/dev/null || true
    fi
    tlab_pause

    say "shopapi_t denials — input to the generator"
    present_cmd "sepac denials shopapi --since boot --last 20"
    tlab_checkpoint "Enforcing; shopapi_t; first-ship curls produced AVCs. Go back to the Mac."
}

part_generate() {
    e2e_banner "QA VM — turn denials into shopapi.te"
    cd "${HOME}/selinux-pac"
    if [[ "${E2E_SKIP_EXPORT}" -eq 1 ]]; then
        say "Prod captured the /feature-spool denial"
        present_cmd "ls -l ${APP_ROOT}/policy_out/avc.log && wc -l ${APP_ROOT}/policy_out/avc.log"
        tlab_pause
        say "Generate from the prod log"
        present_cmd "sepac generate shopapi --skip-export --apply --approve execmem"
    else
        say "relabel, then generate from AVCs"
        present_cmd "sudo restorecon -Rv /opt/shopapi /var/lib/shopapi /var/log/shopapi /run/shopapi && sepac generate shopapi --apply --approve execmem"
    fi
    say "Forbidden-pattern gate"
    present_cmd "sepac check shopapi"
    say "Load the module on QA and label the port"
    present_cmd "sepac load shopapi && sudo semanage port -a -t shopapi_port_t -p tcp $(shop_port) 2>/dev/null || sudo semanage port -m -t shopapi_port_t -p tcp $(shop_port)"
    tlab_pause
    say "The generated policy"
    present_cmd "ls -l ${APP_ROOT}/selinux/shopapi/shopapi.te ${APP_ROOT}/selinux/shopapi/shopapi.fc ${APP_ROOT}/selinux/shopapi/policy_version.txt && head -20 ${APP_ROOT}/selinux/shopapi/shopapi.te"
    tlab_checkpoint "selinux/shopapi/shopapi.te generated from AVCs. Go back to the Mac."
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
