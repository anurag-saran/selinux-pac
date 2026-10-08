#!/usr/bin/env bash
#
# reject_compiled_bypasses.sh — Compile each review-bypass fixture and fail
# if the compiled-policy gate accepts it. A fixture that does not compile
# does not prove the gate, so that fails the job too.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/compile_policy.sh
source "${SCRIPT_DIR}/lib/compile_policy.sh"

fixtures=(
    interface-macro
    split-line
    permissive-declaration
    file-type-star
    unconfined-domain-type
    load-policy-setenforce
    sys-module-sys-admin
    fc-relabel-shadow
    foreign-entrypoint
    dontaudit-forbidden
)

root="${PROJECT_ROOT}/docs/examples/fixtures/compiled-bypasses"
fail=0
for name in "${fixtures[@]}"; do
    dir="${root}/${name}"
    if [[ ! -f "${dir}/bypass.te" || ! -f "${dir}/bypass.fc" ]]; then
        echo "bypass fixture ${name} is missing bypass.te or bypass.fc" >&2
        exit 1
    fi
    pp="$(mktemp)"
    if ! compile_policy_module "${dir}" bypass "${pp}"; then
        echo "bypass fixture ${name} did not compile" >&2
        rm -f "${pp}"
        exit 1
    fi
    rm -f "${pp}"
    set +e
    out="$(POLICY_MODULE=bypass SELINUX_DOMAIN=bypass_t bash "${SCRIPT_DIR}/validate_policy_semantics.sh" "${dir}" 2>&1)"
    rc=$?
    set -e
    rm -f "${dir}/bypass.pp" "${dir}/bypass.mod"
    if [[ "${rc}" -eq 0 ]]; then
        echo "bypass fixture ${name} was accepted" >&2
        printf '%s\n' "${out}" >&2
        fail=1
    else
        echo "rejected ${name}"
    fi
done

if [[ "${fail}" -ne 0 ]]; then
    echo "compiled-policy gate accepted a review bypass" >&2
    exit 1
fi
echo "compiled-policy gate rejected every review bypass"
