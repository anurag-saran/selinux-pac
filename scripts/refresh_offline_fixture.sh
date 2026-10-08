#!/usr/bin/env bash
#
# refresh_offline_fixture.sh — Sync offline/generated/ with selinux/ after a policy bump.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="${POLICY_APP:-myapp}"
DEST="${PROJECT_ROOT}/docs/examples/fixtures/offline/generated"

mkdir -p "${DEST}"
cp "${PROJECT_ROOT}/selinux/${APP_NAME}.te" "${DEST}/${APP_NAME}.te"
cp "${PROJECT_ROOT}/selinux/${APP_NAME}.fc" "${DEST}/${APP_NAME}.fc"
echo "Updated ${DEST}/ from selinux/"
