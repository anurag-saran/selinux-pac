# e2e_demo.sh — shared talk-track helpers for demo_e2e_*.sh (source only)
# Requires scripts/lib/training_lab_runner.sh already sourced.

E2E_DRY="${E2E_DRY:-0}"
E2E_PART="${E2E_PART:-all}"
E2E_SKIP_EXPORT="${E2E_SKIP_EXPORT:-0}"
# shellcheck source=lab_env.sh
_e2e_here="${BASH_SOURCE[0]%/*}"
source "${_e2e_here}/lab_env.sh"
unset _e2e_here
lab_env_load

e2e_usage_common() {
    cat <<EOF
For the ~20 min single-host customer talk, see scripts/demo_present.sh.
Guide: docs/demo/301-CUSTOMER.md  ·  docs/demo/203-RHEL_TWO_HOST.md

Options:
  --auto       No Enter pauses. On the Mac script, also SSH and run the VM talk tracks.
  --no-type    Print commands instantly (no typewriter)
  --dry-run    Type and explain only — do not run commands (no SSH client required)
  --skip-export  (rhel-qa --part generate) use existing policy_out/avc.log
  -h, --help   Show help
EOF
}

# Hide OpenSSH PQ / banner warnings in talk-track output. Displayed commands
# stay plain `ssh` / `scp`; the wrapper is on PATH for the rest of the script.
e2e_install_quiet_ssh() {
    local real_ssh real_scp bindir
    # Dry-run never opens a connection (laptop eval with no VMs / no SSH client).
    [[ "${E2E_DRY:-0}" -eq 1 ]] && return 0
    if [[ -n "${E2E_SSH_WRAP_DIR:-}" && -x "${E2E_SSH_WRAP_DIR}/ssh" ]]; then
        return 0
    fi
    real_ssh="$(command -v ssh || true)"
    real_scp="$(command -v scp || true)"
    [[ -n "${real_ssh}" && -x "${real_ssh}" && -n "${real_scp}" && -x "${real_scp}" ]] || return 0
    bindir="$(mktemp -d "${TMPDIR:-/tmp}/selinux-pac-e2e-ssh.XXXXXX")"
    cat >"${bindir}/ssh" <<EOF
#!/bin/sh
exec $(printf '%q' "${real_ssh}") -o BatchMode=yes -o ConnectTimeout=15 -o LogLevel=ERROR "\$@"
EOF
    cat >"${bindir}/scp" <<EOF
#!/bin/sh
exec $(printf '%q' "${real_scp}") -o BatchMode=yes -o ConnectTimeout=15 -o LogLevel=ERROR "\$@"
EOF
    chmod +x "${bindir}/ssh" "${bindir}/scp"
    E2E_SSH_WRAP_DIR="${bindir}"
    export PATH="${bindir}:${PATH}"
}

e2e_auto_flags() {
    local flags="--auto"
    if [[ "${TLAB_NO_TYPE}" -eq 1 ]]; then
        flags+=" --no-type"
    fi
    if [[ "${E2E_DRY}" -eq 1 ]]; then
        flags+=" --dry-run"
    fi
    if [[ "${E2E_SKIP_EXPORT}" -eq 1 ]]; then
        flags+=" --skip-export"
    fi
    echo "${flags}"
}

e2e_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto) TLAB_AUTO=1; shift ;;
            --no-type) TLAB_NO_TYPE=1; shift ;;
            --dry-run|--say-only) E2E_DRY=1; shift ;;
            --part) E2E_PART="$2"; shift 2 ;;
            --skip-export) E2E_SKIP_EXPORT=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
        esac
    done
    lab_env_require
    e2e_install_quiet_ssh
}

e2e_banner() {
    echo
    echo -e "${TLAB_BOLD}${TLAB_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${TLAB_NC}"
    echo -e "${TLAB_BOLD}  $*${TLAB_NC}"
    echo -e "${TLAB_BOLD}${TLAB_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${TLAB_NC}"
    echo
}

e2e_run() {
    local cmd="$1"
    tlab_type_line "${cmd}"
    if [[ "${E2E_DRY}" -eq 1 ]]; then
        echo -e "${TLAB_DIM}(dry-run — not executing)${TLAB_NC}"
        echo
        return 0
    fi
    eval "${cmd}"
    echo
}

e2e_run_expect_fail() {
    local cmd="$1"
    tlab_type_line "${cmd}"
    if [[ "${E2E_DRY}" -eq 1 ]]; then
        echo -e "${TLAB_DIM}(dry-run — this command is expected to fail)${TLAB_NC}"
        echo
        return 0
    fi
    set +e
    eval "${cmd}"
    local rc=$?
    set -e
    echo
    echo -e "${TLAB_YELLOW}Exit ${rc} — that failure is the point of this step.${TLAB_NC}"
    echo
}

# Run a command; on failure print a warning and continue (GitHub/auth hiccups).
e2e_run_allow_fail() {
    local cmd="$1"
    tlab_type_line "${cmd}"
    if [[ "${E2E_DRY}" -eq 1 ]]; then
        echo -e "${TLAB_DIM}(dry-run — not executing)${TLAB_NC}"
        echo
        return 0
    fi
    set +e
    eval "${cmd}"
    local rc=$?
    set -e
    echo
    if [[ "${rc}" -ne 0 ]]; then
        echo -e "${TLAB_YELLOW}Exit ${rc} — continuing the talk track. Fix auth/network and re-run this step if needed.${TLAB_NC}"
        echo
    fi
    return 0
}

# Interactive: print the switch-window talk track and wait.
# --auto: optionally run $2 (usually ssh … demo_e2e_rhel_*.sh --auto) instead of waiting.
e2e_handoff() {
    local msg="$1"
    local auto_cmd="${2:-}"
    echo
    echo -e "${TLAB_BOLD}${TLAB_YELLOW}>>> Switch windows${TLAB_NC}"
    echo -e "${TLAB_YELLOW}${msg}${TLAB_NC}"
    echo
    if [[ "${TLAB_AUTO}" -eq 1 && -n "${auto_cmd}" ]]; then
        e2e_run "${auto_cmd}"
        return 0
    fi
    tlab_pause
}

e2e_require_mac() {
    if [[ "$(uname -s)" != Darwin ]]; then
        echo "This script is the Mac talk track. On a RHEL VM use demo_e2e_rhel_qa.sh or demo_e2e_rhel_prod.sh." >&2
        exit 1
    fi
}

e2e_require_rhel() {
    local who="$1"
    if [[ "$(uname -s)" == Darwin ]]; then
        echo "This script runs ON ${who}, not on the Mac." >&2
        echo "On the Mac: ssh ${E2E_SSH_USER}@${DEV_HOST}   or   ssh ${E2E_SSH_USER}@${PROD_HOST}" >&2
        exit 1
    fi
    if ! command -v getenforce >/dev/null 2>&1; then
        echo "getenforce not found — this is not a SELinux host." >&2
        exit 1
    fi
}

# Talk-track legend for customer-visible files under selinux/ on rhel-qa.
e2e_explain_selinux_tree() {
    local root="${1:-.}"
    tlab_explain "This folder is the shopapi policy product in selinux-pac. Git reviews these files. Prod never clones them — it gets an RPM built from them. The types-only seed is committed; after generate --apply this is the first real allow list."
    e2e_run "ls -la '${root}/selinux/shopapi/shopapi.te' '${root}/selinux/shopapi/shopapi.fc' '${root}/selinux/shopapi/policy_version.txt'"
    tlab_explain "selinux/shopapi/shopapi.te — type enforcement. Seed is types + init_daemon_domain. After generate --apply it is the first real allow list from AVCs. No JVM cookbook; no execmem unless the log showed it."
    tlab_explain "selinux/shopapi/shopapi.fc — file_contexts. restorecon applies this. The generator adds rows when AVCs show unlabeled or wrong-type files. /var/spool/shopapi is intentionally absent until the outage generate."
    tlab_explain "selinux/shopapi/policy_version.txt — one line, kept in lockstep with policy_module(shopapi, X.Y.Z). PRs and the shopapi-selinux RPM bump this."
    tlab_explain "selinux/shopapi/shopapi.pp — compiled binary (gitignored). Built on rhel-qa only. A Mac cannot compile SELinux."
    if [[ -d "${root}/selinux/payments" ]]; then
        tlab_explain "selinux/payments/ — CI multi-module fixture. Not this talk."
    fi
    tlab_explain "policy_out/ (created at generate) — avc.log, generated .te/.fc before --apply copies them into selinux/shopapi/, pr_body.md is the GitHub PR text."
}

e2e_ensure_hostname() {
    local want="${1:?}"
    tlab_explain "Guest hostname ${want} so the prompt matches the talk track (not a leftover rhel-dev image name)."
    e2e_run "sudo hostnamectl set-hostname ${want}"
    e2e_run "hostname"
}

# UTM VMs often have RTC drift. ausearch -ts recent/boot then looks at the wrong
# window even when /var/log/audit/audit.log already has the denials.
e2e_sync_clock() {
    tlab_explain "If the VM clock is skewed, ausearch -ts recent is empty. NTP first, then collect AVCs."
    e2e_run "timedatectl status | sed -n '1,8p'"
    e2e_run "sudo timedatectl set-ntp true"
    e2e_run "sudo chronyc makestep 2>/dev/null || sudo chronyc -a makestep 2>/dev/null || true"
}

e2e_shopapi_avcs() {
    local extra="${1:-}"
    tlab_explain "Read denials from audit.log (not ausearch -ts recent) so a skewed clock cannot hide them."
    e2e_run "sudo grep 'avc:  denied' /var/log/audit/audit.log | grep -E 'shopapi_t${extra}' | tail -20 || echo 'WARN: no shopapi_t AVC in audit.log'"
}
