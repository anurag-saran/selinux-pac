#!/usr/bin/env bash
#
# semodule_restore_dontaudit.sh — Run semodule -B unless another app is still soaking.
# semodule -B is host-wide. One app locking down must not hide denials for another.
#
set -euo pipefail

APP=""
STATE_ROOT="${SOAK_STATE_ROOT:-/var/lib/selinux-policy-ops}"

usage() {
    echo "Usage: $(basename "$0") --app NAME [--state-root DIR]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --state-root) STATE_ROOT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

[[ -n "${APP}" ]] || { echo "semodule_restore_dontaudit: --app is required" >&2; exit 2; }

shopt -s nullglob
for marker in "${STATE_ROOT}"/*/selinux_canary_deployed_at; do
    [[ -f "${marker}" ]] || continue
    other="$(basename "$(dirname "${marker}")")"
    if [[ "${other}" != "${APP}" ]]; then
        echo "skip semodule -B: ${other} still has a canary marker" >&2
        exit 0
    fi
done

semodule -B
