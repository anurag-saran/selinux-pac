#!/usr/bin/env bash
#
# demo_present.sh — Three-app customer talk: nothing to do → tune it → build it.
#
#   bash scripts/demo_present.sh --dry-run --profile customer
#   bash scripts/demo_present.sh --preflight
#   bash scripts/demo_present.sh --profile customer
#   bash scripts/demo_present.sh --profile technical --app shopapi
#   bash scripts/demo_present.sh --acts 0,1,2
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/training_lab_runner.sh
source "${SCRIPT_DIR}/lib/training_lab_runner.sh"
# shellcheck source=lib/e2e_demo.sh
source "${SCRIPT_DIR}/lib/e2e_demo.sh"
# shellcheck source=lib/demo_estate.sh
source "${SCRIPT_DIR}/lib/demo_estate.sh"
# shellcheck source=lib/vendor_policy_check.sh
source "${SCRIPT_DIR}/lib/vendor_policy_check.sh"

TLAB_PS1='demo# '
PROFILE="customer"
ACTS=""
PREFLIGHT=0
DEMO_APP="shopapi"
SKIP_AI=1
OPEN_PR=0
LLM_SUMMARY=0
PREFLIGHT_FAIL=0

CUSTOMER_ACTS="0,1,2,3"
TECHNICAL_ACTS="0,1,2,3,4,5"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Single-host customer talk (~20 min): vendor Tomcat already enforcing (App A) →
tune inherited Tomcat (App B, no .te) → generate for Spring Boot (shopapi).

  One RHEL box. Do not run this as the three-host production walkthrough.
  Multi-host (~45 min, Mac + rhel-qa + rhel-prod):  bash scripts/demo_e2e_mac.sh
  Guide: docs/demo/202-DEMO_GUIDE.md

Options:
  --profile customer|technical   customer = acts 0,1,2,3 (~20 min)
                                 technical = 0–5 (adds PR + points at demo_e2e_mac.sh)
  --acts LIST                    Comma-separated act numbers (overrides --profile)
  --preflight                    Check the host and exit (pass/fail table)
  --dry-run                      Print narration + commands; execute nothing
  --skip-ai                      Do not require OPENAI_API_KEY (default)
  --open-pr                      Preflight requires gh auth
  --auto                         No Enter pauses
  --no-type                      Instant command echo
  -h, --help

Laptop with no RHEL:  bash scripts/demo_present.sh --dry-run --profile customer
Unprepared VM:        make demo-bootstrap
Second Act 2 on the same host:  bash scripts/reset_demo_vms.sh --dev-only
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
        --skip-ai) SKIP_AI=1; shift ;;
        --open-pr) OPEN_PR=1; shift ;;
        --llm-summary) LLM_SUMMARY=1; SKIP_AI=0; shift ;;
        --auto) TLAB_AUTO=1; shift ;;
        --no-type) TLAB_NO_TYPE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

if [[ "${DEMO_APP}" != "shopapi" ]]; then
    DEMO_APP="shopapi"
fi

if [[ -z "${ACTS}" ]]; then
    case "${PROFILE}" in
        customer) ACTS="${CUSTOMER_ACTS}" ;;
        technical) ACTS="${TECHNICAL_ACTS}" ;;
        *) echo "Unknown --profile ${PROFILE} (use customer|technical)" >&2; exit 2 ;;
    esac
fi

demo_expect() {
    echo -e "${TLAB_DIM}Expected:${TLAB_NC} $*"
}

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

# Prints the first connect boolean that is on; return 1 if none are on.
app_b_connect_boolean_on() {
    local b
    for b in tomcat_can_network_connect jws6_can_network_connect \
        jws_can_network_connect httpd_can_network_connect; do
        if getsebool "${b}" 2>/dev/null | grep -Fq -- '--> on'; then
            printf '%s' "${b}"
            return 0
        fi
    done
    return 1
}

app_b_reset_hint() {
    echo "bash scripts/reset_demo_vms.sh --dev-only   (or: make demo-bootstrap after deleting the three host tunings)"
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
        pf_row "WOULD" "App B boolean" "tomcat_can_network_connect off (fix: setsebool -P … off)"
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

    if [[ "${SKIP_AI}" -eq 0 && "${LLM_SUMMARY}" -eq 1 ]]; then
        if [[ -n "${OPENAI_API_KEY:-}" ]]; then
            pf_row "PASS" "OPENAI_API_KEY" "set"
        else
            pf_row "FAIL" "OPENAI_API_KEY" "unset" "export OPENAI_API_KEY or pass --skip-ai"
        fi
    else
        pf_row "PASS" "OPENAI_API_KEY" "not required (deterministic / --skip-ai)"
    fi

    echo
    if [[ "${PREFLIGHT_FAIL}" -ne 0 ]]; then
        echo "Preflight FAILED. Missing App A: make demo-bootstrap. Already-tuned App B: $(app_b_reset_hint)"
        return 1
    fi
    echo "Preflight PASSED. variant=$(demo_variant) domain=$(demo_tomcat_domain)"
    return 0
}

act0_triage() {
    e2e_banner "Act 0 — Triage (~2 min)"
    tlab_explain "Three situations. We decline the generator until we are in the third."
    tlab_explain "App A: greenfield Tomcat on ${APP_A_PORT} — vendor policy. App B: inherited Tomcat on ${APP_B_PORT} talking to a payment gateway. shopapi: Spring Boot, no vendor module."
    demo_expect "vendor check names a loaded tomcat/jws module for App A, and situation=none for shopapi"

    if [[ "${E2E_DRY}" -eq 1 ]]; then
        echo "[INFO] TRIAGE situation=loaded app=tomcat module=jws6_tomcat (or tomcat) class=tomcat action=tune"
        echo "[INFO] TRIAGE situation=none app=shopapi action=generate"
        echo "[INFO] variant would be jws (jws6_tomcat_t) or tomcat (tomcat_t) — bootstrap prints which"
        echo "(live distro Tomcat: module tomcat is loaded, but seinfo may show files_unconfined_type — Act 1/2 denials will not fire)"
    else
        vendor_policy_preflight --report --app-name tomcat --unit "$(demo_tomcat_service)" || true
        vendor_policy_preflight --report --app-name shopapi --unit shopapi.service || true
        echo "variant=$(demo_variant) domain=$(demo_tomcat_domain)"
        ps -eo label,comm 2>/dev/null | grep -E 'tomcat|java|shopapi' | head -n 20 || true
        if demo_selinux_type_unconfined "$(demo_tomcat_domain)"; then
            tlab_explain "Loaded module tomcat is not confinement. Distro $(demo_tomcat_domain) is unconfined_domain_type — Act 1/2 denials will not fire. JWS jws6_tomcat_t would. This talk still generates only for shopapi."
        fi
    fi
    tlab_explain "This demo will generate policy only for shopapi. Tomcat is vendor-covered."
    tlab_checkpoint "Audience can place their estate: covered / tune / generate."
    tlab_pause
}

act1_app_a() {
    local domain unconfined=0
    domain="$(demo_tomcat_domain)"
    e2e_banner "Act 1 — App A standard Tomcat (~1 min, no changes)"
    tlab_explain "Greenfield deploy on standard paths and port ${APP_A_PORT}. Already enforcing. Zero work from us. Both Tomcat apps share one domain — SELinux is not isolating A from B; that would be separate instances or containers."
    if [[ "${E2E_DRY}" -eq 1 ]]; then
        tlab_explain "If live seinfo shows files_unconfined_type on ${domain} (RHEL distro tomcat_t), forbidden.jsp returns UNEXPECTED_READ and there is no AVC. That is the distro-Tomcat beat. JWS jws6_tomcat_t is confined and returns DENIED."
    elif demo_selinux_type_unconfined "${domain}"; then
        unconfined=1
        tlab_explain "Distro ${domain} is files_unconfined_type. The forbidden-file read will succeed. JWS jws6_tomcat_t would deny. We still authored nothing."
    fi
    e2e_run "getenforce"
    demo_expect "Enforcing"
    e2e_run "ps -eo label,comm | grep -E 'tomcat|jsvc' | head || true"
    demo_expect "scontext ... ${domain}  (jws6_tomcat_t if JWS, tomcat_t if distro Tomcat)"
    e2e_run "curl -sS http://127.0.0.1:${APP_A_PORT}/standard/"
    demo_expect "App A standard / OK"
    tlab_explain "Now a request that must fail on a confined vendor domain — reading ${APP_A_FORBIDDEN_PATH}, world-readable so DAC cannot hide the AVC."
    e2e_run "curl -sS http://127.0.0.1:${APP_A_PORT}/standard/forbidden.jsp"
    if [[ "${unconfined}" -eq 1 ]]; then
        demo_expect "UNEXPECTED_READ ${APP_A_FORBIDDEN_PATH}  (distro ${domain} is files_unconfined_type)"
        e2e_run "seinfo -t ${domain} -x | tr ',' '\n' | grep unconfined || true"
        e2e_run "sudo ausearch -m avc -ts recent 2>/dev/null | grep -E 'out-of-scope|user_home_t|forbidden' | tail -n 5 || true"
        demo_expect "no AVC — unconfined domains do not deny this read"
        tlab_checkpoint "Vendor module is loaded, but distro tomcat_t is unconfined. JWS jws6-tomcat-selinux is the confined vendor domain. We authored nothing."
    else
        demo_expect "DENIED ... (not UNEXPECTED_READ)"
        e2e_run "sudo ausearch -m avc -ts recent 2>/dev/null | grep -E 'out-of-scope|user_home_t|forbidden' | tail -n 5 || true"
        demo_expect "scontext=...:${domain}:s0  tclass=file  denied { read }"
        tlab_checkpoint "Vendor policy, already enforcing, a real denial on demand. We authored nothing."
    fi
    tlab_pause
}

# Return 0 if ausearch -ts recent matches PATTERN. Dry-run always 0 (show the fix).
act2_has_avc() {
    local pattern="$1"
    if [[ "${E2E_DRY}" -eq 1 ]]; then
        return 0
    fi
    sudo ausearch -m avc -ts recent 2>/dev/null | grep -E "${pattern}" >/dev/null 2>&1
}

act2_fix_if_avc() {
    local what="$1"
    local pattern="$2"
    local fix="$3"
    if [[ "${E2E_DRY}" -eq 1 ]]; then
        e2e_run "${fix}"
        return 0
    fi
    if act2_has_avc "${pattern}"; then
        e2e_run "${fix}"
    else
        echo "No AVC matching /${pattern}/ for ${what} — skipping that one-line fix. Do not invent a .te."
    fi
}

act2_app_b() {
    local fctx modules_before
    fctx="$(demo_tomcat_fcontext_type)"
    if [[ "${E2E_DRY}" -eq 1 ]]; then
        modules_before="unchanged"
    else
        modules_before="$(demo_semodule_l | wc -l | tr -d ' ')"
    fi

    e2e_banner "Act 2 — App B inherited Tomcat (~5 min, live tune)"
    tlab_explain "Someone else had ${APP_A_PORT}, so this instance listens on ${APP_B_PORT}. Content landed in ${APP_B_DATA}. It calls a payment gateway. That is a normal estate, not a lab trick. audit2why is the manual form of what our generator automates — we show it first."
    tlab_explain "If a probe produces no AVC, we say so and skip that fix. Observed behaviour beats assumed behaviour. Port first: if name_bind failed at start, HTTP on ${APP_B_PORT} never comes up."

    tlab_explain "Probe 1 — port: connector ${APP_B_PORT}"
    e2e_run "curl -sS -o /dev/null -w '%{http_code}\n' --connect-timeout 2 http://127.0.0.1:${APP_B_PORT}/inherited/ || true"
    e2e_run "sudo ausearch -m avc -ts recent 2>/dev/null | grep name_bind | tail -n 10 || true"
    e2e_run "sudo ausearch -m avc -ts recent 2>/dev/null | audit2why | tail -n 30 || true"
    demo_expect "name_bind on unreserved_port_t → semanage port -a -t http_port_t -p tcp ${APP_B_PORT}"
    act2_fix_if_avc "port ${APP_B_PORT}" "name_bind" \
        "sudo semanage port -a -t http_port_t -p tcp ${APP_B_PORT} || sudo semanage port -m -t http_port_t -p tcp ${APP_B_PORT}"
    if [[ "${E2E_DRY}" -eq 1 ]] || act2_has_avc "name_bind"; then
        e2e_run "sudo systemctl restart $(demo_tomcat_service)"
    fi
    e2e_run "curl -sS http://127.0.0.1:${APP_B_PORT}/inherited/ || true"

    tlab_explain "Probe 2 — label: ${APP_B_DATA} (user_home_t on purpose)"
    e2e_run "curl -sS http://127.0.0.1:${APP_B_PORT}/inherited/data.jsp || true"
    e2e_run "sudo ausearch -m avc -ts recent 2>/dev/null | grep -E 'appdata|user_home_t' | tail -n 10 || true"
    e2e_run "sudo ausearch -m avc -ts recent 2>/dev/null | audit2why | tail -n 30 || true"
    demo_expect "mislabeled ${APP_B_DATA} → semanage fcontext + restorecon (no .te)"
    act2_fix_if_avc "label ${APP_B_DATA}" "appdata|user_home_t" \
        "sudo semanage fcontext -a -t ${fctx} '${APP_B_DATA}(/.*)?' || sudo semanage fcontext -a -t tomcat_var_lib_t '${APP_B_DATA}(/.*)?'"
    if [[ "${E2E_DRY}" -eq 1 ]] || act2_has_avc "appdata|user_home_t"; then
        e2e_run "sudo restorecon -Rv ${APP_B_DATA}"
    fi
    e2e_run "curl -sS http://127.0.0.1:${APP_B_PORT}/inherited/data.jsp || true"

    tlab_explain "Probe 3 — boolean: outbound gateway"
    e2e_run "curl -sS http://127.0.0.1:${APP_B_PORT}/inherited/gateway.jsp || true"
    e2e_run "sudo ausearch -m avc -ts recent 2>/dev/null | grep -E 'name_connect|network_connect' | tail -n 10 || true"
    e2e_run "sudo ausearch -m avc -ts recent 2>/dev/null | audit2why | tail -n 30 || true"
    demo_expect "Was caused by a boolean (tomcat_can_network_connect or jws equivalent) → setsebool -P … on"
    if [[ "${E2E_DRY}" -eq 1 ]]; then
        e2e_run "sudo setsebool -P tomcat_can_network_connect on"
        echo "(dry-run — live: use the boolean audit2why names, often jws6_can_network_connect)"
    elif act2_has_avc "name_connect|network_connect"; then
        local b enabled=0
        for b in tomcat_can_network_connect jws6_can_network_connect jws_can_network_connect httpd_can_network_connect; do
            if getsebool "${b}" >/dev/null 2>&1; then
                e2e_run "sudo setsebool -P ${b} on"
                enabled=1
                break
            fi
        done
        if [[ "${enabled}" -eq 0 ]]; then
            echo "No known connect boolean on this host — skipping. Do not invent a .te."
        fi
    else
        echo "No AVC matching name_connect for outbound boolean — skipping that one-line fix. Do not invent a .te."
    fi
    e2e_run "curl -sS http://127.0.0.1:${APP_B_PORT}/inherited/gateway.jsp || true"

    tlab_explain "Optional beat: --tune-report classifies the same App B denials and prints the commands we just ran. It does not write a .te."
    demo_expect "semanage fcontext / setsebool / semanage port — zero policy module"
    if [[ "${E2E_DRY}" -eq 1 ]]; then
        echo "bash scripts/dev_generate_policy.sh --tune-report --app-name tomcat --unit $(demo_tomcat_service)"
        echo "semanage fcontext -a -t ${fctx} \"${APP_B_DATA}(/.*)?\"  &&  restorecon -Rv ${APP_B_DATA}"
        echo "setsebool -P tomcat_can_network_connect on"
        echo "semanage port -a -t http_port_t -p tcp ${APP_B_PORT}"
        echo "(dry-run — live: policy_out/tune_report.md; still no .te)"
    else
        e2e_run "bash scripts/dev_generate_policy.sh --tune-report --app-name tomcat --unit $(demo_tomcat_service)" || true
    fi

    tlab_explain "Proof: three probes, one-line host fixes only when a denial was real, zero policy authored."
    e2e_run "git -C ${PROJECT_ROOT} status --short selinux/ 2>/dev/null || echo '(no git metadata on this host — selinux/ still unauthored)'"
    demo_expect "empty — nothing under selinux/"
    e2e_run "sudo semodule -l | wc -l"
    demo_expect "${modules_before} — unchanged; we did not load a new module"
    if [[ "${E2E_DRY}" -eq 1 ]]; then
        tlab_checkpoint "Three probes, one-line fixes only when a denial was real, zero .te. If you were about to write a module for App B, the app was configured wrong."
    elif demo_selinux_type_unconfined "$(demo_tomcat_domain)"; then
        tlab_checkpoint "Distro tomcat_t is unconfined — App B probes produced no AVC, so we skipped the tunings. Zero .te. JWS would have needed the three host commands. shopapi is still the generate target."
    else
        tlab_checkpoint "Three probes, one-line fixes only when a denial was real, zero .te. If you were about to write a module for App B, the app was configured wrong."
    fi
    tlab_pause
}

act3_generate() {
    e2e_banner "Act 3 — Spring Boot shopapi: the generator is allowed"
    tlab_explain "No vendor module for Spring Boot. ExecStart is a private copy of the JRE launcher at /opt/shopapi/bin/java (shopapi_exec_t). /usr/bin/java is shared bin_t and cannot be the entrypoint. SELinuxContext= still sets shopapi_t."
    e2e_run "systemctl cat shopapi.service | grep -E 'SELinuxContext|ExecStart'"
    demo_expect "SELinuxContext=system_u:system_r:shopapi_t:s0"
    e2e_run "ps -o label=,comm= -C java | head"
    demo_expect "shopapi_t  java   (after the types-only seed is loaded)"
    local shop_port
    shop_port="$(demo_manifest_http_port "${PROJECT_ROOT}/config/shopapi.manifest.yml")"
    tlab_explain "Exercise endpoints under the permissive seed so the AVC log is real. Types-only seed is committed. Allows come from those AVCs — not a JVM cookbook. execmem is needs_review if and only if the AVC log shows it."
    e2e_run "curl -sS http://127.0.0.1:${shop_port}/health || true"
    e2e_run "curl -sS http://127.0.0.1:${shop_port}/state || true"
    e2e_run "curl -sS http://127.0.0.1:${shop_port}/log || true"
    e2e_run "sudo ausearch -m avc -ts recent | grep shopapi_t | tail -n 20 || true"
    e2e_run "sudo bash scripts/dev_generate_policy.sh --apply --allow-needs-review --app-name shopapi --app-root ${PROJECT_ROOT}"
    demo_expect "generator runs; vendor preflight lets shopapi through; findings.json lists observed verdicts"
    tlab_checkpoint "This is the first time we authored policy. We declined twice first."
    tlab_pause
}

act4_pr() {
    e2e_banner "Act 4 — PR (technical)"
    tlab_explain "Policy PR on the app tree. CI forbidden-patterns already ran at generate time."
    e2e_run "bash scripts/validate_forbidden_patterns.sh selinux/shopapi"
    if [[ "${OPEN_PR}" -eq 1 ]]; then
        e2e_run_allow_fail "bash scripts/demo_open_generated_pr.sh"
    else
        echo "Skip gh pr (pass --open-pr to enable)."
    fi
    tlab_pause
}

act5_pipeline() {
    e2e_banner "Act 5 — Canary / soak / fail (technical)"
    tlab_explain "Two-host pipeline for shopapi: canary, soak, talk-only enforce, /feature-spool outage, rollback, recanary."
    echo "Mac: bash scripts/demo_e2e_mac.sh"
    echo "QA:  bash scripts/demo_e2e_rhel_qa.sh"
    echo "Prod: bash ~/e2e-demo/demo_e2e_rhel_prod.sh"
    tlab_pause
}

run_act() {
    local n="$1"
    case "${n}" in
        0) act0_triage ;;
        1) act1_app_a ;;
        2) act2_app_b ;;
        3) act3_generate ;;
        4) act4_pr ;;
        5) act5_pipeline ;;
        *) echo "Unknown act ${n}" >&2; exit 2 ;;
    esac
}

main() {
    if [[ "${PREFLIGHT}" -eq 1 ]]; then
        run_preflight
        exit $?
    fi
    e2e_banner "SELinux PaC — nothing to do, then tune, then build"
    echo "profile=${PROFILE} acts=${ACTS} app=${DEMO_APP} dry-run=${E2E_DRY}"
    echo "Unprepared host: make demo-bootstrap    Laptop: --dry-run --profile customer"
    echo "Second Act 2 on this host: bash scripts/reset_demo_vms.sh --dev-only"
    echo
    local IFS=','
    local act
    for act in ${ACTS}; do
        act="$(echo "${act}" | tr -d ' ')"
        [[ -n "${act}" ]] || continue
        run_act "${act}"
    done
    tlab_checkpoint "Done. Covered → tuned → generated. Restraint first."
}

main
