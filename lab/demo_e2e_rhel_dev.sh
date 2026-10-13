#!/usr/bin/env bash
# Legacy name from when the QA VM was called rhel-dev.
# Deprecated 2026-09-18. Remove after 2026-12-31.
# Presenters: bash lab/demo_e2e_rhel_qa.sh
set -euo pipefail
echo "deprecated (remove after 2026-12-31): demo_e2e_rhel_dev.sh — use demo_e2e_rhel_qa.sh" >&2
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/demo_e2e_rhel_qa.sh" "$@"
