#!/usr/bin/env bash
#
# validate_policy_semantics.sh — sesearch assertions on compiled policy module.
# Uses an isolated targeted store (does not load the module into the live kernel).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
POLICY_DIR="${1:-${PROJECT_ROOT}/selinux}"
MODULE_NAME="${POLICY_MODULE:-myapp}"
DOMAIN="${SELINUX_DOMAIN:-myapp_t}"

# shellcheck source=lib/compile_policy.sh
source "${SCRIPT_DIR}/lib/compile_policy.sh"
# shellcheck source=lib/policy_isolated_store.sh
source "${SCRIPT_DIR}/lib/policy_isolated_store.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Types this module declares. A type only mentioned inside require { } is
# foreign: an entrypoint allow on it is not "our" exec type.
module_declared_types() {
    awk '
        /^[[:space:]]*require[[:space:]]*\{/ { in_require = 1 }
        in_require && /\}/ { in_require = 0; next }
        in_require { next }
        /^[[:space:]]*type[[:space:]]+[A-Za-z_]/ {
            gsub(/;/, "", $2)
            print $2
        }
    ' "$1"
}

if [[ "${1:-}" == "--print-declared-types" ]]; then
    [[ -n "${2:-}" && -f "${2}" ]] || exit 2
    module_declared_types "${2}"
    exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
    log_error "validate_policy_semantics.sh needs root (isolated policy store copy)"
    exit 1
fi
if ! has_selinux_devel || ! command -v sesearch >/dev/null 2>&1 || ! command -v seinfo >/dev/null 2>&1 || [[ ! -d /var/lib/selinux/targeted ]]; then
    log_error "Need selinux-policy-devel, setools-console, and selinux-policy-targeted (run on rhel-qa or CI Stream 9)"
    exit 1
fi

pp="${POLICY_DIR}/${MODULE_NAME}.pp"
compile_policy_module "${POLICY_DIR}" "${MODULE_NAME}" "${pp}"

store_prefix="$(isolated_store_create)"
trap 'isolated_store_destroy "${store_prefix}"' EXIT
kern="$(isolated_store_kern "${store_prefix}")"

semodule -r "${MODULE_NAME}" -s targeted -p "${store_prefix}" 2>/dev/null || true
semodule -s targeted -p "${store_prefix}" -i "${pp}"
[[ -f "${kern}" ]] || {
    log_error "missing ${kern} after semodule -i"
    exit 1
}

fail=0
if sesearch --direct --allow -s "${DOMAIN}" -t shadow_t -p read "${kern}" 2>/dev/null | grep -q .; then
    log_error "unexpected allow ${DOMAIN} -> shadow_t:read"
    fail=1
fi
if sesearch --direct --allow -s "${DOMAIN}" -t unlabeled_t "${kern}" 2>/dev/null | grep -q .; then
    log_error "unexpected allow ${DOMAIN} -> unlabeled_t"
    fail=1
fi
allows_file="$(mktemp)"
declared_file="$(mktemp)"
seinfo_file="$(mktemp)"
perm_file="$(mktemp)"
dontaudit_file="$(mktemp)"
sesearch --allow -s "${DOMAIN}" "${kern}" >"${allows_file}" 2>/dev/null || true
sesearch --dontaudit --direct -s "${DOMAIN}" "${kern}" >"${dontaudit_file}" 2>/dev/null || true
seinfo -x -t "${DOMAIN}" "${kern}" >"${seinfo_file}" 2>/dev/null || true
seinfo --permissive "${kern}" >"${perm_file}" 2>/dev/null || true
module_declared_types "${POLICY_DIR}/${MODULE_NAME}.te" >"${declared_file}"
if ! python3 "${PROJECT_ROOT}/cli/policy_audit.py" \
    --allows-file "${allows_file}" \
    --dontaudit-file "${dontaudit_file}" \
    --seinfo-file "${seinfo_file}" \
    --permissive-file "${perm_file}" \
    --declared-types-file "${declared_file}" \
    --domain "${DOMAIN}"; then
    fail=1
fi
fc_active="${store_prefix}/var/lib/selinux/targeted/active/file_contexts"
if [[ -f "${fc_active}" ]] && awk -v declared="${declared_file}" '
    BEGIN {
        while ((getline line < declared) > 0) {
            if (line != "") types[line] = 1
        }
        close(declared)
    }
    /^#/ || NF < 2 { next }
    {
        path = $1
        if (index(path, "/etc/shadow") != 1) next
        n = split($NF, parts, ":")
        if (n >= 3 && (parts[3] in types)) hit = 1
    }
    END { exit hit ? 0 : 1 }
' "${fc_active}"; then
    log_error "compiled file contexts relabel /etc/shadow to a type this module declares"
    fail=1
fi
rm -f "${allows_file}" "${seinfo_file}" "${perm_file}" "${declared_file}" "${dontaudit_file}"

if [[ "${fail}" -ne 0 ]]; then
    log_error "Semantic policy check failed"
    exit 1
fi

log_info "Semantic policy checks passed for ${DOMAIN}"
