#!/usr/bin/env bash
#
# validate_forbidden_patterns.sh — CI gate for over-permissive or invalid SELinux syntax
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
POLICY_DIR="${1:-${PROJECT_ROOT}/selinux}"
MODULE_NAME="${POLICY_MODULE:-myapp}"
DOMAIN="${SELINUX_DOMAIN:-myapp_t}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

te="${POLICY_DIR}/${MODULE_NAME}.te"
fc="${POLICY_DIR}/${MODULE_NAME}.fc"

[[ -f "${te}" ]] || { log_error "Missing ${te}"; exit 1; }
[[ -f "${fc}" ]] || { log_error "Missing ${fc}"; exit 1; }

fail=0

check_fail() {
    log_error "$1"
    fail=1
}

log_info "Checking forbidden patterns in ${te}"

if grep -qE 'allow\s+\w+\s+\*:' "${te}"; then
    check_fail "Wildcard object type in allow rule"
fi

if grep -qE 'allow\s+\w+\s+\w+:\*\s' "${te}"; then
    check_fail "Wildcard object class in allow rule"
fi

if grep -qE 'allow\s+\w+\s+\*:\*\s+\*\s+\*' "${te}"; then
    check_fail "Fully wildcard allow rule"
fi

if grep -qE 'allow\s+\w+\s+self:\*' "${te}"; then
    check_fail "Forbidden allow rule targeting self:* (over-broad)"
fi

if grep -qE 'allow\s+\w+\s+bin_t:file[[:space:]]+\{[^}]*execute' "${te}"; then
    check_fail "Forbidden bin_t:file execute — label app binaries with dedicated exec types in .fc"
fi

if grep -qE '^module\s+' "${te}"; then
    check_fail "Use policy_module() syntax, not bare 'module' declaration"
fi

if ! python3 -c "
import re, pathlib, sys
te = pathlib.Path('${te}').read_text()
prefix = '${MODULE_NAME}_'
if re.search(r'require\s*\{[^}]*\btype\s+' + re.escape(prefix), te, re.DOTALL):
    sys.exit(1)
" 2>/dev/null; then
    check_fail "Custom types declared inside require block"
fi

while IFS= read -r priv; do
    [[ -n "${priv}" ]] || continue
    if grep -qE "allow[[:space:]]+[^[:space:]]+[[:space:]]+${priv}[[:space:]]*:" "${te}"; then
        check_fail "Forbidden allow rule targeting high-privilege type: ${priv}"
    fi
done < <(PYTHONPATH="${PROJECT_ROOT}/cli" python3 -c 'from policy_rules import FORBIDDEN_TARGET_TYPES
print("\n".join(sorted(FORBIDDEN_TARGET_TYPES)))')

if grep -qE 'allow[[:space:]]+[^[:space:]]+[[:space:]]+var_t:file[[:space:]]+\{[^}]*write' "${te}"; then
    check_fail "Forbidden broad var_t:file write — use dedicated application types"
fi

if ! grep -q 'policy_module' "${te}"; then
    check_fail "Missing policy_module() declaration"
fi

if ! grep -q "${DOMAIN}" "${te}"; then
    check_fail "Domain ${DOMAIN} not referenced in ${te}"
fi

# FCOS permissive overlay — no file contexts; main myapp.fc labels paths.
if [[ "${MODULE_NAME}" != "myapp_canary" ]]; then
    for token in "/opt/${MODULE_NAME}" "/var/lib/${MODULE_NAME}" "${MODULE_NAME}_exec_t" "${MODULE_NAME}_var_lib_t"; do
        if ! grep -q "${token}" "${fc}"; then
            check_fail "fc_content missing expected path/type: ${token}"
        fi
    done
fi

if [[ "${fail}" -ne 0 ]]; then
    exit 1
fi

log_info "Forbidden-pattern checks passed for ${MODULE_NAME}"
