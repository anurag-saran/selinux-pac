#!/usr/bin/env bash
#
# validate_rpm_ops_parity.sh — Ensure selinux-policy-ops.spec lists match scripts/ sources.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPS_DIR="${ROOT}/scripts"

EXPECTED=(
    verify_file_contexts.sh
    wait_for_endpoints.sh
    monitor_avc.sh
    post_deploy_report.sh
    collect_soak_facts.sh
    check_soak_ready.sh
    check_soak_gate.sh
    check_soak_days.sh
    record_soak_day.sh
    semodule_restore_dontaudit.sh
    lib/avc_query.sh
    lib/manifest_shell.sh
    lib/app_manifest.py
    lib/soak_net_new.py
)

missing=0
for rel in "${EXPECTED[@]}"; do
    if [[ ! -f "${OPS_DIR}/${rel}" ]]; then
        echo "MISSING source: scripts/${rel}" >&2
        missing=1
    fi
done

spec="${ROOT}/packaging/selinux-policy-ops.spec"
for rel in "${EXPECTED[@]}"; do
    base="${rel##*/}"
    if [[ "${rel}" == lib/* ]]; then
        if ! grep -q "selinux-policy-ops/lib/${base}" "${spec}"; then
            echo "SPEC missing lib file: ${base}" >&2
            missing=1
        fi
    else
        if ! grep -q "selinux-policy-ops/${base}" "${spec}"; then
            echo "SPEC missing script: ${base}" >&2
            missing=1
        fi
    fi
done

if [[ "${missing}" -ne 0 ]]; then
    exit 1
fi
echo "OK selinux-policy-ops sources match packaging spec allowlist"
