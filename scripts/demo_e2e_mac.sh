#!/usr/bin/env bash
#
# demo_e2e_mac.sh — Typewriter talk track for the Mac (Ansible controller).
#
# shopapi (Spring Boot): generate → PR → prod canary/soak →
# talk-only enforce → /feature-spool 500 → rollback → generate on rhel-qa →
# second PR → recanary.
#
#   bash scripts/demo_e2e_mac.sh
#   bash scripts/demo_e2e_mac.sh --dry-run
#   bash scripts/demo_e2e_mac.sh --auto --no-type
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/training_lab_runner.sh
source "${SCRIPT_DIR}/lib/training_lab_runner.sh"
# shellcheck source=lib/e2e_demo.sh
source "${SCRIPT_DIR}/lib/e2e_demo.sh"

TLAB_PS1='${USER}@mac selinux-pac %'
DEMO_PROD_FORCE_ENFORCE="${DEMO_PROD_FORCE_ENFORCE:-true}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Presenter script for THIS Mac. Demo application is shopapi (Spring Boot).
Three-host production walkthrough (~45 min): this window + rhel-qa + rhel-prod.
Do not run this as the first customer conversation.

$(e2e_usage_common)

Other windows (do not run those scripts here unless using --auto):
  ssh ${E2E_SSH_USER:-SSH_USER}@${DEV_HOST:-QA_HOST}   →  bash ~/selinux-pac/scripts/demo_e2e_rhel_qa.sh
  ssh ${E2E_SSH_USER:-SSH_USER}@${PROD_HOST:-PROD_HOST}  →  bash ~/e2e-demo/demo_e2e_rhel_prod.sh
EOF
}

mac_copy_prod_bundle() {
    tlab_explain "Prod gets shopapi and this talk track over scp — not a git clone."
    e2e_run "ssh ${E2E_SSH_USER}@${PROD_HOST} 'mkdir -p ~/e2e-demo/lib ~/e2e-demo/scripts/lib ~/e2e-demo/config ~/e2e-demo/demo/shopapi/target'"
    e2e_run "scp scripts/demo_e2e_rhel_prod.sh ${E2E_SSH_USER}@${PROD_HOST}:~/e2e-demo/"
    e2e_run "scp scripts/lib/e2e_demo.sh scripts/lib/training_lab_runner.sh ${E2E_SSH_USER}@${PROD_HOST}:~/e2e-demo/lib/"
    e2e_run "scp scripts/demo_bootstrap.sh ${E2E_SSH_USER}@${PROD_HOST}:~/e2e-demo/scripts/"
    e2e_run "scp scripts/lib/demo_estate.sh scripts/lib/app_manifest.py scripts/lib/manifest_shell.sh ${E2E_SSH_USER}@${PROD_HOST}:~/e2e-demo/scripts/lib/"
    e2e_run "scp config/shopapi.manifest.yml ${E2E_SSH_USER}@${PROD_HOST}:~/e2e-demo/config/"
    e2e_run "scp -r demo/shopapi/. ${E2E_SSH_USER}@${PROD_HOST}:~/e2e-demo/demo/shopapi/"
}

mac_scp_generated_from_dev() {
    tlab_explain "Copy generated shopapi sources into this tool checkout (the PR). Also copy the compiled .pp so Ansible can ship it."
    e2e_run "mkdir -p policy_out selinux/shopapi"
    e2e_run "scp ${E2E_SSH_USER}@${DEV_HOST}:~/selinux-pac/selinux/shopapi/shopapi.te ${E2E_SSH_USER}@${DEV_HOST}:~/selinux-pac/selinux/shopapi/shopapi.fc ${E2E_SSH_USER}@${DEV_HOST}:~/selinux-pac/selinux/shopapi/policy_version.txt ${E2E_SSH_USER}@${DEV_HOST}:~/selinux-pac/selinux/shopapi/shopapi.pp selinux/shopapi/"
    e2e_run_allow_fail "scp ${E2E_SSH_USER}@${DEV_HOST}:~/selinux-pac/policy_out/pr_body.md policy_out/pr_body.md"
    e2e_run "ls -l selinux/shopapi/shopapi.te selinux/shopapi/shopapi.pp; echo '--- version ---'; cat selinux/shopapi/policy_version.txt"
}

mac_open_policy_pr() {
    tlab_explain "Admin gate #1: a GitHub PR on selinux-pac for selinux/shopapi/. CODEOWNERS review selinux/."
    e2e_run_allow_fail "bash scripts/demo_open_generated_pr.sh"
    tlab_checkpoint "If gh is logged in, a PR URL printed. Do not build RPMs until this PR is merged to main."
    tlab_pause
    mac_policy_best_practices
}

mac_policy_best_practices() {
    tlab_explain "Admin gate #2: forbidden-patterns on shopapi. The generator already ran this script. The pull request also runs offline-tests, compiled-policy, and version-consistency."
    e2e_run "POLICY_MODULE=shopapi SELINUX_DOMAIN=shopapi_t bash scripts/validate_forbidden_patterns.sh selinux/shopapi"
    e2e_run_allow_fail "command -v gh >/dev/null && gh pr checks || echo 'gh not logged in or no PR yet — local forbidden-patterns already passed'"
}

mac_canary_enforce_dev() {
    tlab_explain "Canary: Ansible copies shopapi.pp to ${DEV_HOST}, loads it, and puts ONLY shopapi_t in log-but-do-not-block mode. The whole OS stays Enforcing."
    e2e_run "ansible-playbook -i ansible/inventory.dev.yml ansible/deploy_canary.yml"
    tlab_checkpoint "failed=0. Recent shopapi_t events should be 0 raw / 0 net-new."
    tlab_pause

    tlab_lab_only_banner "Dev inventory waits 0 days so this talk can lock down. Never copy soak_min_days: 0 onto prod (inventory.production.yml stays at 7 days). The gate is real; QA is lab-only."
    tlab_explain "QA canary/enforce uses soak_min_days: 0. Production inventory is 7 days plus a change ticket."
    e2e_run "ansible-playbook -i ansible/inventory.dev.yml ansible/enforce_production.yml -e change_ticket=LAB"
    tlab_checkpoint "failed=0. Host getenforce is still Enforcing; shopapi_t is no longer permissive."
}

mac_ship_prod() {
    local mode="${1:-soak_demo}"
    tlab_explain "Ship only after the PR is merged. Build the RPMs from merged main, not from the unmerged checkout."
    e2e_run "git fetch origin main && git checkout main && git pull --ff-only origin main"
    e2e_run "bash packaging/build_rpms.sh"
    e2e_run "ls dist/*.rpm"
    tlab_pause

    tlab_explain "Prod installs from a dnf repo with gpgcheck=1. Do not copy RPMs onto the host and install them by hand."
    if [[ -z "${SELINUX_GPG_NAME:-}" ]]; then
        echo "No signing key: SELINUX_GPG_NAME is unset. Run bash scripts/lab_signing_setup.sh, then export SELINUX_GPG_NAME and SELINUX_RPM_REPO. Do not install unsigned RPMs on prod."
        echo "Expected: spoken stop — no signing key; do not install unsigned RPMs on prod"
    else
        e2e_run "bash packaging/publish_internal.sh"
        echo "Expected: repo snippet with gpgcheck=1"
    fi
    tlab_explain "deploy_canary.yml installs the RPMs with dnf and sets shopapi_t permissive before it restarts the service."

    e2e_handoff "On the PROD VM window run:
  bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part rpms
The service stays the unconfined JVM. This window does not install the policy RPM.
Press Enter here when that is what you showed." \
        "ssh ${E2E_SSH_USER}@${PROD_HOST} 'bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part rpms $(e2e_auto_flags)'"

    tlab_explain "inventory.production.yml talks to ${PROD_HOST}. Canary is the install."
    e2e_run "ansible-playbook -i ansible/inventory.production.yml ansible/deploy_canary.yml --limit canary"
    tlab_pause

    if [[ "${mode}" == "soak_demo" ]]; then
        tlab_print_section "Soak: /feature-spool is denied, so the gate refuses"
        e2e_handoff "On the PROD VM window run:
  bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part soak
Curl /health /state /log /feature-spool. shopapi_t is permissive, so the page can still return 200. ausearch must show a shopapi denial for /var/spool/shopapi.
Press Enter here when the denial is on screen." \
            "ssh ${E2E_SSH_USER}@${PROD_HOST} 'bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part soak $(e2e_auto_flags)'"

        tlab_explain "soak_monitor must fail. The spool write is not in the module we just shipped."
        e2e_run_expect_fail "ansible-playbook -i ansible/inventory.production.yml ansible/soak_monitor.yml --limit canary"
        tlab_pause

        e2e_handoff "On the PROD VM window run:
  bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part soak-avc
/var/lib/selinux-policy-ops/shopapi/selinux_soak_last_fail.avc should exist. Leave it there. Press Enter here when you have shown that." \
            "ssh ${E2E_SSH_USER}@${PROD_HOST} 'bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part soak-avc $(e2e_auto_flags)'"

        tlab_explain "Enforce without force_enforce. That flag would skip this AVC failure and the seven-day count. We do not pass it. The day count is not how you get past a denial."
        e2e_run_expect_fail "ansible-playbook -i ansible/inventory.production.yml ansible/enforce_production.yml -e change_ticket=DEMO"
        tlab_checkpoint "The gate refused. shopapi_t stays permissive. We do not force_enforce a failed soak."
        return 0
    fi

    tlab_explain "Recanary soak: the new module allows the spool write, so net-new is 0."
    e2e_handoff "On the PROD VM window run:
  bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part soak-clean
/health /state /log /feature-spool should return 200, and ausearch should show no shopapi denial since this canary.
Press Enter here when you have seen that." \
        "ssh ${E2E_SSH_USER}@${PROD_HOST} 'bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part soak-clean $(e2e_auto_flags)'"
    e2e_run "ansible-playbook -i ansible/inventory.production.yml ansible/soak_monitor.yml --limit canary"
    tlab_pause
    tlab_explain "soak_status is read-only. inventory.production.yml still wants 7 days. The AVC gate passed."
    e2e_run "ansible-playbook -i ansible/inventory.production.yml ansible/soak_status.yml --limit canary"
    tlab_pause
    tlab_explain "This recording cannot wait 7 days. force_enforce skips the day count and is written in the deploy report. It is not a way past a failed soak."
    e2e_run "ansible-playbook -i ansible/inventory.production.yml ansible/enforce_production.yml -e change_ticket=DEMO -e force_enforce=true"
    tlab_checkpoint "AVC gate passed. force_enforce recorded the day-count skip. shopapi_t is enforcing."
}

mac_copy_prod_avc_to_dev() {
    tlab_explain "Prod has no generator. Copy the AVC export to rhel-qa ~/selinux-pac/policy_out/avc.log."
    e2e_run "scp ${E2E_SSH_USER}@${PROD_HOST}:/tmp/prod-feature-spool.avc /tmp/prod-feature-spool.avc"
    e2e_run "ssh ${E2E_SSH_USER}@${DEV_HOST} 'mkdir -p ~/selinux-pac/policy_out'"
    e2e_run "scp /tmp/prod-feature-spool.avc ${E2E_SSH_USER}@${DEV_HOST}:~/selinux-pac/policy_out/avc.log"
    e2e_run "ssh ${E2E_SSH_USER}@${DEV_HOST} 'wc -l ~/selinux-pac/policy_out/avc.log'"
}

e2e_parse_args "$@"
e2e_require_mac
cd "${PROJECT_ROOT}"

e2e_banner "MAC — the remote control (no SELinux on this laptop)"
tlab_why "macOS cannot enforce SELinux. This window talks to two RHEL VMs over SSH: QA ${DEV_HOST} and prod ${PROD_HOST}."
tlab_explain "Look at the prompt. If it says rhel-qa or rhel-prod, you are in the wrong window."
tlab_explain "Story: Spring Boot shopapi has no vendor module. Generate on rhel-qa → PR → prod canary. The soak curls /feature-spool, the monitor fails, and enforce without force_enforce refuses. Fix on rhel-qa, second PR, recanary, clean soak, then enforce. The day-count skip is force_enforce and is written in the deploy report. The outage and rollback beat comes after that."
tlab_pause

tlab_print_section "Part 1 — Can the Mac reach the VMs?"
e2e_run "bash scripts/setup_rhel_hosts.sh write --qa-host ${DEV_HOST} --prod-host ${PROD_HOST} --user ${E2E_SSH_USER}"
tlab_checkpoint "You should see Wrote …inventory.dev.yml and …inventory.production.yml (app_name shopapi)."
tlab_pause

e2e_run "bash scripts/setup_rhel_hosts.sh ping"
tlab_checkpoint "SUCCESS / pong for rhel-qa and rhel-prod."
tlab_pause

e2e_run "bash scripts/setup_rhel_hosts.sh doctor"
tlab_checkpoint "Each host prints Enforcing, then paths to ausearch and sesearch."
tlab_pause

tlab_explain "rsync copies this tool checkout onto rhel-qa (shopapi lives here). Prod gets the shopapi bundle — no git clone."
e2e_run "bash scripts/sync_rhel_dev.sh"
mac_copy_prod_bundle
tlab_pause

e2e_run "bash scripts/setup_rhel_hosts.sh bootstrap"
tlab_pause

e2e_handoff "On the QA VM window run:
  bash ~/selinux-pac/scripts/demo_e2e_rhel_qa.sh --part app
That installs shopapi with the types-only seed and curls /health /state /log (not /feature-spool).
Press Enter here when ausearch shows shopapi denials." \
    "ssh ${E2E_SSH_USER}@${DEV_HOST} 'bash ~/selinux-pac/scripts/demo_e2e_rhel_qa.sh --part app $(e2e_auto_flags)'"

tlab_explain "Copy the JAR QA just built so prod does not need Maven."
e2e_run "ssh ${E2E_SSH_USER}@${PROD_HOST} 'mkdir -p ~/e2e-demo/demo/shopapi/target'"
e2e_run "scp ${E2E_SSH_USER}@${DEV_HOST}:/opt/shopapi/shopapi.jar ${E2E_SSH_USER}@${PROD_HOST}:~/e2e-demo/demo/shopapi/target/shopapi.jar"

e2e_handoff "On the PROD VM window run:
  bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part app
That installs shopapi only (unconfined JVM, no policy module).
Press Enter here when curl /health returns 200." \
    "ssh ${E2E_SSH_USER}@${PROD_HOST} 'bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part app $(e2e_auto_flags)'"

e2e_handoff "On the QA VM window run:
  bash ~/selinux-pac/scripts/demo_e2e_rhel_qa.sh --part generate
That reads the audit log and writes the first real shopapi.te from those AVCs.
Press Enter here when compile_and_validate has built selinux/shopapi/shopapi.pp." \
    "ssh ${E2E_SSH_USER}@${DEV_HOST} 'bash ~/selinux-pac/scripts/demo_e2e_rhel_qa.sh --part generate $(e2e_auto_flags)'"

tlab_print_section "Part 4 — Copy generated policy and open a GitHub PR"
mac_scp_generated_from_dev
tlab_pause
mac_open_policy_pr
tlab_pause

tlab_print_section "Part 5 — Canary + lab enforce on QA"
mac_canary_enforce_dev
tlab_pause

tlab_print_section "Part 6 — Prod soak hits /feature-spool; the gate refuses; then the fix is enforced"
mac_ship_prod soak_demo
tlab_pause

tlab_explain "The denial is already in /tmp/prod-feature-spool.avc. Generate the spool allow on rhel-qa. Do not semodule -i on prod."
mac_copy_prod_avc_to_dev
tlab_pause

e2e_handoff "On the QA VM window generate from the prod log:
  bash ~/selinux-pac/scripts/demo_e2e_rhel_qa.sh --part generate --skip-export
Press Enter here when the second compile finishes." \
    "ssh ${E2E_SSH_USER}@${DEV_HOST} 'bash ~/selinux-pac/scripts/demo_e2e_rhel_qa.sh --part generate --skip-export $(e2e_auto_flags)'"

mac_scp_generated_from_dev
tlab_pause
mac_open_policy_pr
tlab_pause

tlab_explain "Merge that PR. Recanary the new module on QA, then rebuild RPMs and ship prod. The clean soak must pass before enforce."
mac_canary_enforce_dev
tlab_pause
mac_ship_prod recanary
tlab_pause

tlab_print_section "Part 7 — Outage and rollback"
tlab_explain "This beat is the enforcing denial and the rollback. It is what you show when shopapi_t is enforcing and the loaded module does not allow /var/spool/shopapi. After the fix above, that allow is loaded, so /feature-spool returns 200. Say the rollback playbook anyway: it puts the domain back to permissive and getenforce stays Enforcing."
e2e_handoff "On the PROD VM window run:
  bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part fail
When the spool allow is not loaded, curl /feature-spool returns 500 and /tmp/prod-feature-spool.avc is written. After Part 6, expect HTTP 200." \
    "ssh ${E2E_SSH_USER}@${PROD_HOST} 'bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part fail $(e2e_auto_flags)'"

tlab_explain "Admin step: get the app running again. emergency_rollback.yml marks shopapi_t permissive. Host getenforce stays Enforcing. We do not semodule -i on prod."
e2e_run "ansible-playbook -i ansible/inventory.production.yml ansible/emergency_rollback.yml"
tlab_pause

e2e_handoff "On the PROD VM window run:
  bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part restore
curl /health and /feature-spool should return 200 again. Press Enter here when the app is up." \
    "ssh ${E2E_SSH_USER}@${PROD_HOST} 'bash ~/e2e-demo/demo_e2e_rhel_prod.sh --part restore $(e2e_auto_flags)'"

echo
echo -e "${TLAB_BOLD}End of the Mac talk track.${TLAB_NC} Full script: docs/demo/302-TECHNICAL.md"
echo
