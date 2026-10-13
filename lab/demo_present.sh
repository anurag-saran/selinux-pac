#!/usr/bin/env bash
#
# demo_present.sh — Three-app customer talk: nothing to do → tune it → build it.
#
# Each step prints at most one caption line, types the command, and waits for
# Enter before it runs. The presenter explains; the screen stays quiet.
#
#   bash lab/demo_present.sh --dry-run --profile customer
#   bash lab/demo_present.sh --preflight
#   bash lab/demo_present.sh --profile customer
#   bash lab/demo_present.sh --profile technical
#   bash lab/demo_present.sh --acts 0,1,2
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export PATH="${PROJECT_ROOT}/bin:${PATH}"
# shellcheck source=lib/training_lab_runner.sh
source "${SCRIPT_DIR}/lib/training_lab_runner.sh"
# shellcheck source=lib/e2e_demo.sh
source "${SCRIPT_DIR}/lib/e2e_demo.sh"
# shellcheck source=lib/demo_estate.sh
source "${SCRIPT_DIR}/lib/demo_estate.sh"

TLAB_PS1='demo# '
PROFILE="customer"
ACTS=""
PREFLIGHT=0
OPEN_PR=0
PREFLIGHT_FAIL=0
STEP=1
DEMO_DRY_VARIANT="distro"
DEMO_DRY_UNCONFINED=1

CUSTOMER_ACTS="0,1,2,3,6"
TECHNICAL_ACTS="0,1,2,3,4,5"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Single-host customer talk (~20 min): triage finds distro Tomcat unconfined (App A) →
tune inherited Tomcat only when a denial is real (App B, no .te) → generate for
Spring Boot (shopapi) → show the enforcing payoff.

  One RHEL box. Do not run this as the three-host production walkthrough.
  Multi-host (~45 min, Mac + rhel-qa + rhel-prod):  bash lab/demo_e2e_mac.sh
  Guide: docs/demo/301-CUSTOMER.md

Each command is typed, then waits for Enter before it runs.

Options:
  --profile customer|technical   customer = acts 0,1,2,3,6 (~20 min)
                                 technical = 0–5 (PR and the 302 pointer; no enforcing payoff)
  --acts LIST                    Comma-separated act numbers (overrides --profile)
  --preflight                    Check the host and exit (pass/fail table)
  --dry-run                      Type the commands and a sample result; execute nothing
  --variant distro|jws           Dry-run host (default distro). Prints what that
                                 host shows: distro tomcat_t is unconfined;
                                 jws is jws6_tomcat_t and confined.
  --open-pr                      Act 4 opens the PR (preflight requires gh auth)
  --no-step                      Run each command as soon as it is typed
  --auto                         No Enter at all (CI)
  --no-type                      Instant command echo
  -h, --help

Laptop with no RHEL:  bash lab/demo_present.sh --dry-run --profile customer
Unprepared VM:        make demo-bootstrap
Second Act 2 on the same host:  bash lab/reset_demo_vms.sh --dev-only
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE="$2"; shift 2 ;;
        --acts) ACTS="$2"; shift 2 ;;
        --app)
            if [[ "$2" != "shopapi" ]]; then
                echo "This demo is shopapi only. Ignoring --app $2" >&2
            fi
            shift 2
            ;;
        --preflight) PREFLIGHT=1; shift ;;
        --dry-run|--say-only) E2E_DRY=1; shift ;;
        --variant)
            case "$2" in
                distro|jws) DEMO_DRY_VARIANT="$2"; shift 2 ;;
                *) echo "Unknown --variant ${2} (use distro|jws)" >&2; exit 2 ;;
            esac
            ;;
        --open-pr) OPEN_PR=1; shift ;;
        --no-step) STEP=0; shift ;;
        --auto) TLAB_AUTO=1; shift ;;
        --no-type) TLAB_NO_TYPE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

if [[ "${E2E_DRY}" -eq 1 ]]; then
    if [[ "${DEMO_DRY_VARIANT}" == "jws" ]]; then
        DEMO_TOMCAT_VARIANT="jws"
        DEMO_DRY_UNCONFINED=0
    else
        DEMO_TOMCAT_VARIANT="tomcat"
        DEMO_DRY_UNCONFINED=1
    fi
fi

if [[ -z "${ACTS}" ]]; then
    case "${PROFILE}" in
        customer) ACTS="${CUSTOMER_ACTS}" ;;
        technical) ACTS="${TECHNICAL_ACTS}" ;;
        *) echo "Unknown --profile ${PROFILE} (use customer|technical)" >&2; exit 2 ;;
    esac
fi

# ── Step runner ──────────────────────────────────────────────────────────────

# One caption line above a command, shown as a shell comment.
say() {
    echo -e "${TLAB_DIM}# $*${TLAB_NC}"
}

# Type the command and leave the cursor at the end of the line.
present_type() {
    local cmd="$1" i
    echo -n -e "${TLAB_GREEN}${TLAB_PS1}${TLAB_NC}"
    if [[ "${TLAB_NO_TYPE}" -eq 1 ]]; then
        printf '%s' "${cmd}"
        return 0
    fi
    for ((i = 0; i < ${#cmd}; i++)); do
        printf '%s' "${cmd:i:1}"
        sleep "${TLAB_TYPE_DELAY}"
    done
}

# Wait for Enter. Keys are not echoed, so a stray key cannot garble the line.
present_wait() {
    if [[ "${TLAB_AUTO}" -eq 0 && "${STEP}" -eq 1 ]]; then
        read -r -s _ || true
    fi
    echo
}

# present_cmd COMMAND [run|fail] [DRY_RUN_SAMPLE]
#   run   A non-zero exit is shown in yellow and the talk keeps going.
#   fail  The step is meant to be refused. Exit 0 is the surprise.
# --dry-run prints DRY_RUN_SAMPLE (what a good screen shows) instead of running.
present_cmd() {
    local cmd="$1" mode="${2:-run}" sample="${3:-}" rc
    present_type "${cmd}"
    present_wait
    if [[ "${E2E_DRY}" -eq 1 ]]; then
        echo -e "${TLAB_DIM}(dry-run)${sample:+ ${sample}}${TLAB_NC}"
        echo
        return 0
    fi
    set +e
    eval "${cmd}"
    rc=$?
    set -e
    echo
    if [[ "${mode}" == "fail" ]]; then
        if [[ "${rc}" -ne 0 ]]; then
            echo -e "${TLAB_YELLOW}exit ${rc}: blocked on purpose${TLAB_NC}"
        else
            echo -e "${TLAB_RED}exit 0: this step should have been blocked${TLAB_NC}"
        fi
        echo
    elif [[ "${rc}" -ne 0 ]]; then
        echo -e "${TLAB_YELLOW}exit ${rc}${TLAB_NC}"
        echo
    fi
    return 0
}

# ── Preflight (not shown to the audience) ────────────────────────────────────

pf_row() {
    local status="$1" name="$2" detail="$3" hint="${4:-}"
    printf '%-6s  %-28s  %s\n' "${status}" "${name}" "${detail}"
    if [[ "${status}" == "FAIL" ]]; then
        PREFLIGHT_FAIL=1
        if [[ -n "${hint}" ]]; then
            echo "        → ${hint}"
        fi
    elif [[ "${status}" == "WARN" && -n "${hint}" ]]; then
        echo "        → ${hint}"
    fi
}

port_listening() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | grep -Eq ":${port}[[:space:]]"
        return $?
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
        return $?
    fi
    return 1
}

# True if APP_B_PORT is in the local customizations (semanage -C), not the
# stock http_port_t list. A second Act 2 on a labelled port produces no name_bind.
app_b_port_labelled() {
    local port="${APP_B_PORT}"
    command -v semanage >/dev/null 2>&1 || return 1
    if semanage port -l -C 2>/dev/null | awk -v p="${port}" '
        $2 == "tcp" {
            line = $0
            sub(/^[^ \t]+[ \t]+tcp[ \t]+/, "", line)
            n = split(line, parts, /,[ \t]*/)
            for (i = 1; i <= n; i++) {
                gsub(/[ \t]/, "", parts[i])
                if (parts[i] == p) exit 0
                if (parts[i] ~ /^[0-9]+-[0-9]+$/) {
                    split(parts[i], r, /-/)
                    if ((p + 0) >= (r[1] + 0) && (p + 0) <= (r[2] + 0)) exit 0
                }
            }
        }
        END { exit 1 }
    '; then
        return 0
    fi
    return 1
}

app_b_fcontext_custom() {
    command -v semanage >/dev/null 2>&1 || return 1
    if semanage fcontext -l -C 2>/dev/null | grep -F "${APP_B_DATA}" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Prints the first JWS connect boolean that is on. Distro Tomcat has no
# tomcat_can_network_connect. Never treat httpd_can_network_connect as Tomcat's.
app_b_connect_boolean_on() {
    local b
    for b in jws6_can_network_connect jws_can_network_connect; do
        if getsebool "${b}" 2>/dev/null | grep -Fq -- '--> on'; then
            printf '%s' "${b}"
            return 0
        fi
    done
    return 1
}

app_b_reset_hint() {
    echo "bash lab/reset_demo_vms.sh --dev-only   (or: make demo-bootstrap after deleting the three host tunings)"
}

run_preflight() {
    echo
    echo "Demo preflight"
    echo "=============="
    if [[ "${E2E_DRY}" -eq 1 ]]; then
        echo "(dry-run — checks not executed)"
        pf_row "WOULD" "App A HTTP :${APP_A_PORT}" "curl /standard/"
        pf_row "WOULD" "App A confined" "ps -o label=  (jws6_tomcat_t or tomcat_t)"
        pf_row "WOULD" "getenforce" "Enforcing"
        pf_row "WOULD" "tomcat unit" "$(demo_tomcat_service 2>/dev/null || echo tomcat.service)"
        pf_row "WOULD" "shopapi unit" "shopapi.service"
        pf_row "WOULD" "App B port ${APP_B_PORT}" "must not be labelled (fix: semanage port -d -p tcp ${APP_B_PORT})"
        pf_row "WOULD" "App B fcontext" "must not exist for ${APP_B_DATA} (fix: semanage fcontext -d '${APP_B_DATA}(/.*)?')"
        pf_row "WOULD" "App B boolean" "set one only if audit2why names it and getsebool lists it"
        echo
        echo "On a missing or unconfined App A: run make demo-bootstrap"
        echo "On an already-tuned App B: $(app_b_reset_hint)"
        return 0
    fi

    if [[ "$(uname -s)" != "Linux" ]]; then
        pf_row "FAIL" "Linux/RHEL host" "$(uname -s)" "run make demo-bootstrap on a RHEL VM, or --dry-run here"
        echo
        echo "Preflight FAILED. If App A is missing or unconfined: run make demo-bootstrap on a RHEL VM, or --dry-run here"
        return 1
    fi

    local ge
    ge="$(getenforce 2>/dev/null || echo missing)"
    if [[ "${ge}" == "Enforcing" ]]; then
        pf_row "PASS" "getenforce" "${ge}"
    else
        pf_row "FAIL" "getenforce" "${ge}" "setenforce 1 (keep the host Enforcing)"
    fi

    local svc
    svc="$(demo_tomcat_service)"
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
        pf_row "PASS" "Tomcat unit" "${svc} active"
    else
        pf_row "FAIL" "Tomcat unit" "${svc} not active" "run make demo-bootstrap"
    fi

    if curl -sf "http://127.0.0.1:${APP_A_PORT}/standard/" >/dev/null 2>&1 \
        || curl -sf "http://127.0.0.1:${APP_A_PORT}/standard/index.jsp" >/dev/null 2>&1; then
        pf_row "PASS" "App A HTTP" ":${APP_A_PORT}/standard/"
    else
        pf_row "FAIL" "App A HTTP" "not responding on :${APP_A_PORT}" "run make demo-bootstrap"
    fi

    local label
    label="$(ps -eo label,comm 2>/dev/null | awk '/tomcat|jsvc|java/ && /tomcat_t|jws6_tomcat_t/ {print $1; exit}')"
    if [[ -n "${label}" ]]; then
        pf_row "PASS" "App A confined" "${label}"
    else
        local raw
        raw="$(ps -eo label,comm 2>/dev/null | awk '/tomcat|jsvc/ {print $1; exit}')"
        pf_row "FAIL" "App A confined" "${raw:-no tomcat process}" "run make demo-bootstrap"
    fi

    if [[ -f "${APP_A_FORBIDDEN_PATH}" ]]; then
        pf_row "PASS" "App A deny-file" "${APP_A_FORBIDDEN_PATH}"
    else
        pf_row "FAIL" "App A deny-file" "missing ${APP_A_FORBIDDEN_PATH}" "run make demo-bootstrap"
    fi

    if systemctl list-unit-files shopapi.service >/dev/null 2>&1; then
        pf_row "PASS" "shopapi unit" "installed"
    else
        pf_row "FAIL" "shopapi unit" "missing" "run make demo-bootstrap"
    fi

    if port_listening "${APP_A_PORT}"; then
        pf_row "PASS" "port ${APP_A_PORT}" "listening (App A)"
    else
        pf_row "FAIL" "port ${APP_A_PORT}" "not listening" "run make demo-bootstrap"
    fi
    if app_b_port_labelled; then
        pf_row "FAIL" "port ${APP_B_PORT}" "already labelled — Act 2 will not produce a denial" \
            "semanage port -d -p tcp ${APP_B_PORT}   (or: $(app_b_reset_hint))"
    elif port_listening "${APP_B_PORT}"; then
        pf_row "WARN" "port ${APP_B_PORT}" "listening without a custom label — Act 2 name_bind may be silent (distro tomcat_t often may bind unreserved ports)"
    else
        pf_row "PASS" "port ${APP_B_PORT}" "unlabelled and not listening (name_bind still to show)"
    fi

    if demo_selinux_type_unconfined "$(demo_tomcat_domain)"; then
        pf_row "WARN" "App A denials" "$(demo_tomcat_domain) is files_unconfined_type — Act 1/2 file and port denials will not fire (need JWS jws6_tomcat_t). Act 3 shopapi still confines."
    fi

    if app_b_fcontext_custom; then
        pf_row "FAIL" "App B fcontext" "already set for ${APP_B_DATA} — Act 2 label probe will not produce a denial" \
            "semanage fcontext -d '${APP_B_DATA}(/.*)?'   (or: $(app_b_reset_hint))"
    else
        pf_row "PASS" "App B fcontext" "no custom mapping for ${APP_B_DATA}"
    fi

    local b_on
    b_on="$(app_b_connect_boolean_on || true)"
    if [[ -n "${b_on}" ]]; then
        pf_row "FAIL" "App B boolean" "${b_on} is on — Act 2 gateway probe will not produce a denial" \
            "setsebool -P ${b_on} off   (or: $(app_b_reset_hint))"
    else
        pf_row "PASS" "App B boolean" "connect boolean off (or absent)"
    fi

    if [[ "${OPEN_PR}" -eq 1 ]]; then
        if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
            pf_row "PASS" "gh auth" "ok"
        else
            pf_row "FAIL" "gh auth" "missing" "gh auth login (required with --open-pr)"
        fi
    fi

    echo
    if [[ "${PREFLIGHT_FAIL}" -ne 0 ]]; then
        echo "Preflight FAILED. Missing App A: make demo-bootstrap. Already-tuned App B: $(app_b_reset_hint)"
        return 1
    fi
    echo "Preflight PASSED. variant=$(demo_variant) domain=$(demo_tomcat_domain)"
    return 0
}

# ── Acts ─────────────────────────────────────────────────────────────────────

# Distro tomcat_t is unconfined_domain_type. Dry-run uses the variant flag.
# A live host uses the type on the policy.
present_distro_unconfined() {
    if [[ "${E2E_DRY}" -eq 1 && "${DEMO_DRY_UNCONFINED}" -eq 1 ]]; then
        return 0
    fi
    if [[ "${E2E_DRY}" -eq 0 ]] && demo_selinux_type_unconfined "$(demo_tomcat_domain)"; then
        return 0
    fi
    return 1
}

shop_port() {
    demo_manifest_http_port "${PROJECT_ROOT}/config/shopapi.manifest.yml"
}

act0_triage() {
    local svc tomcat_sample
    svc="$(demo_tomcat_service)"
    if present_distro_unconfined; then
        tomcat_sample="[INFO] TRIAGE situation=loaded_unconfined app=tomcat module=tomcat class=tomcat action=confine domain=tomcat_t"
    else
        tomcat_sample="[INFO] TRIAGE situation=loaded app=tomcat module=jws6_tomcat class=tomcat action=tune domain=jws6_tomcat_t"
    fi
    e2e_banner "Triage · does Red Hat already ship policy?"
    say "Tomcat"
    if [[ "${svc}" != "tomcat.service" ]]; then
        present_cmd "sepac triage tomcat --unit ${svc}" run "${tomcat_sample}"
    else
        present_cmd "sepac triage tomcat" run "${tomcat_sample}"
    fi
    say "shopapi (Spring Boot)"
    present_cmd "sepac triage shopapi" run \
        "[INFO] TRIAGE situation=none app=shopapi action=generate"
    if present_distro_unconfined; then
        tlab_checkpoint "Tomcat has a Red Hat module, but tomcat_t is unconfined. shopapi has none: the only app we write policy for."
    else
        tlab_checkpoint "Tomcat is vendor-covered. shopapi has no Red Hat policy: the only app we write policy for."
    fi
    tlab_pause
}

act1_app_a() {
    local domain page
    domain="$(demo_tomcat_domain)"
    page="http://127.0.0.1:${APP_A_PORT}/standard/forbidden.jsp"
    e2e_banner "App A · standard Tomcat: change nothing"
    say "The host is Enforcing"
    present_cmd "getenforce" run "Enforcing"
    say "Tomcat's SELinux domain"
    present_cmd "ps -eo label,comm | grep -E 'tomcat|jsvc'" run "system_u:system_r:${domain}:s0 java"
    say "This page reads a file Tomcat should not touch"
    if present_distro_unconfined; then
        present_cmd "curl -sS ${page}" run "UNEXPECTED_READ ${APP_A_FORBIDDEN_PATH}"
        say "Why it worked"
        present_cmd "seinfo -t ${domain} -x | tr ',' '\n' | grep unconfined" run "files_unconfined_type  unconfined_domain_type"
        tlab_checkpoint "A Red Hat module is loaded, but ${domain} does not confine. We authored nothing."
    else
        present_cmd "curl -sS ${page}" run "DENIED ${APP_A_FORBIDDEN_PATH}"
        say "The denial"
        present_cmd "sudo ausearch -m avc -ts recent | grep ${domain} | tail -n 3" run \
            "avc: denied { read } ... scontext=system_u:system_r:${domain}:s0 ... tclass=file"
        tlab_checkpoint "Red Hat's policy blocked it. We authored nothing."
    fi
    tlab_pause
}

# True if a recent tomcat denial matches PATTERN. Dry-run: true (show the fix).
act2_has_avc() {
    local pattern="$1"
    if [[ "${E2E_DRY}" -eq 1 ]]; then
        return 0
    fi
    sudo ausearch -m avc -ts recent 2>/dev/null | grep tomcat_t | grep -Eq "${pattern}"
}

# The connect boolean audit2why names for a recent tomcat denial, if this host
# has it. Prints nothing otherwise. Never httpd_can_network_connect: that one
# is for httpd.
act2_connect_boolean() {
    local b
    if [[ "${E2E_DRY}" -eq 1 ]]; then
        echo "<boolean audit2why names>"
        return 0
    fi
    act2_has_avc "name_connect|network_connect" || return 0
    b="$(sudo ausearch -m avc -ts recent 2>/dev/null | grep tomcat_t | audit2why 2>/dev/null \
        | grep -oE 'setsebool -P [^ ]+' | awk '{print $3}' | head -n 1 || true)"
    [[ -n "${b}" && "${b}" != "httpd_can_network_connect" ]] || return 0
    getsebool "${b}" >/dev/null 2>&1 || return 0
    printf '%s' "${b}"
}

act2_app_b() {
    local svc fctx b base fixed=0
    svc="$(demo_tomcat_service)"
    fctx="$(demo_tomcat_fcontext_type)"
    base="http://127.0.0.1:${APP_B_PORT}/inherited"
    e2e_banner "App B · inherited Tomcat: tune, do not write"
    say "Port ${APP_B_PORT}"
    present_cmd "curl -s -o /dev/null -w '%{http_code}\n' ${base}/" run "200 (000 if Tomcat could not bind the port)"
    say "Data in ${APP_B_DATA}, labeled user_home_t"
    present_cmd "curl -sS ${base}/data.jsp"
    say "Outbound call to the payment gateway"
    present_cmd "curl -sS ${base}/gateway.jsp"
    say "Any denials? audit2why names the fix"
    if present_distro_unconfined; then
        present_cmd "sepac denials tomcat --why" run \
            "No denials for tomcat_t since recent"
        tlab_checkpoint "No denials, so nothing to fix. Zero policy written."
        tlab_pause
        return 0
    fi
    present_cmd "sepac denials tomcat --why" run \
        "name_bind on unreserved_port_t, read on user_home_t, name_connect: each with its one-line fix"
    if act2_has_avc "name_bind"; then
        say "Label the port, restart Tomcat"
        present_cmd "sudo semanage port -a -t http_port_t -p tcp ${APP_B_PORT} && sudo systemctl restart ${svc}"
        fixed=1
    fi
    if act2_has_avc "appdata|user_home_t"; then
        say "Label the data"
        present_cmd "sudo semanage fcontext -a -t ${fctx} '${APP_B_DATA}(/.*)?' && sudo restorecon -Rv ${APP_B_DATA}"
        fixed=1
    fi
    b="$(act2_connect_boolean)"
    if [[ -n "${b}" ]]; then
        say "Turn on the boolean audit2why named"
        present_cmd "sudo setsebool -P ${b} on"
        fixed=1
    fi
    if [[ "${fixed}" -eq 1 ]]; then
        say "Try again"
        present_cmd "for p in '' data.jsp gateway.jsp; do curl -s -o /dev/null -w \"%{http_code} /inherited/\$p\n\" ${base}/\$p; done" run \
            "200 on all three"
    fi
    tlab_checkpoint "One-line host fixes, only where a denial was real. Zero policy written."
    tlab_pause
}

act3_generate() {
    local port
    port="$(shop_port)"
    e2e_banner "shopapi · write the policy"
    say "shopapi runs in its own domain, permissive for now: logged, not blocked"
    present_cmd "ps -o label=,comm= -C java" run "system_u:system_r:shopapi_t:s0  java"
    say "Use the app"
    present_cmd "for p in health state log; do curl -sS http://127.0.0.1:${port}/\$p; done" run \
        "OK / STATE /var/lib/shopapi/state.txt / LOG /var/log/shopapi/shopapi.log"
    say "What SELinux logged"
    present_cmd "sepac denials shopapi" run \
        "avc: denied { open } ... scontext=...shopapi_t ... permissive=1"
    say "Generate policy from the log"
    present_cmd "sepac generate shopapi" fail \
        "*** GENERATION BLOCKED — domain-weakening permission requires --allow-needs-review (or --allow-needs-review-perm) ***"
    say "A reviewer approves execmem"
    present_cmd "sepac generate shopapi --approve execmem --apply" run \
        "REFUSED: /etc/passwd. bin_t execute accepted: reviewed exception. AVC coverage OK"
    say "Load it on QA (production gets a signed RPM)"
    present_cmd "sepac load shopapi"
    tlab_checkpoint "Policy from the log. execmem needed a sign-off. /etc/passwd was refused."
    tlab_pause
}

act6_enforce_payoff() {
    local port url
    port="$(shop_port)"
    url="http://127.0.0.1:${port}"
    e2e_banner "shopapi · enforce"
    say "Turn enforcement on for shopapi"
    present_cmd "sudo semanage permissive -d shopapi_t"
    say "Same calls, now enforced"
    present_cmd "for p in health state log; do curl -sS ${url}/\$p; done" run \
        "OK / STATE /var/lib/shopapi/state.txt / LOG /var/log/shopapi/shopapi.log"
    say "A new feature the policy has never seen"
    present_cmd "curl -sS ${url}/feature-spool" run '{"status":500,"error":"Internal Server Error","path":"/feature-spool"}'
    say "The denial"
    present_cmd "sepac denials shopapi --enforced" run \
        "avc: denied { open } ... path=/var/spool/shopapi/feature.log ... tcontext=...var_spool_t ... permissive=0"
    say "Generate again"
    present_cmd "sepac generate shopapi --apply" run \
        "LABELING FIXES: /var/spool/shopapi(/.*)? shopapi_var_lib_t"
    say "Load it and fix the label"
    present_cmd "sepac load shopapi" run \
        "Relabeled /var/spool/shopapi from var_spool_t to shopapi_var_lib_t"
    say "Try again"
    present_cmd "curl -sS ${url}/feature-spool" run "SPOOL /var/spool/shopapi/feature.log"
    say "Still enforcing"
    present_cmd "sepac status shopapi" run \
        "Host: Enforcing / Domain: shopapi_t enforcing"
    tlab_checkpoint "Blocked, labeled, fixed. The host never left Enforcing."
    tlab_pause
}

act4_pr() {
    e2e_banner "PR · the CI gate"
    say "The forbidden-pattern gate every policy PR runs"
    present_cmd "sepac check shopapi" run \
        "Forbidden-pattern checks passed for shopapi"
    if [[ "${OPEN_PR}" -eq 1 ]]; then
        say "Open the PR"
        present_cmd "bash lab/demo_open_generated_pr.sh"
    fi
    tlab_pause
}

act5_pipeline() {
    e2e_banner "Pipeline · canary, soak, enforce on two hosts"
    echo "docs/demo/302-TECHNICAL.md"
    echo "  Mac:   bash lab/demo_e2e_mac.sh"
    echo "  QA:    bash lab/demo_e2e_rhel_qa.sh"
    echo "  Prod:  bash ~/e2e-demo/demo_e2e_rhel_prod.sh"
    echo
    tlab_pause
}

run_act() {
    local n="$1"
    case "${n}" in
        0) act0_triage ;;
        1) act1_app_a ;;
        2) act2_app_b ;;
        3) act3_generate ;;
        6) act6_enforce_payoff ;;
        4) act4_pr ;;
        5) act5_pipeline ;;
        *) echo "Unknown act ${n}" >&2; exit 2 ;;
    esac
}

main() {
    cd "${PROJECT_ROOT}"
    if [[ "${PREFLIGHT}" -eq 1 ]]; then
        run_preflight
        exit $?
    fi
    if [[ "${E2E_DRY}" -eq 1 ]]; then
        echo "dry-run  profile=${PROFILE}  acts=${ACTS}  variant=${DEMO_DRY_VARIANT}"
        echo "Unprepared host: make demo-bootstrap.  Second Act 2 on this host: bash lab/reset_demo_vms.sh --dev-only"
    fi
    e2e_banner "SELinux Policy as Code: nothing to do, then tune, then build"
    tlab_pause
    local -a acts
    local act
    IFS=',' read -r -a acts <<<"${ACTS// /}"
    for act in "${acts[@]}"; do
        [[ -n "${act}" ]] || continue
        run_act "${act}"
    done
    if present_distro_unconfined; then
        tlab_checkpoint "Done. Restraint first."
    else
        tlab_checkpoint "Done. Covered → tuned → generated. Restraint first."
    fi
}

main
