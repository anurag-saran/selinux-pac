#!/usr/bin/env bash
#
# serve_lab_repo.sh — Serve the signed lab repo over HTTP from this host.
# The private key stays in GNUPGHOME and is not in the repo directory.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT}/dist/lab-signing.env"
if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "${ENV_FILE}"
    set +a
fi

REPO="${SELINUX_RPM_REPO:-}"
PORT="${SELINUX_REPO_PORT:-8765}"
if [[ -z "${REPO}" || ! -d "${REPO}" ]]; then
    echo "Set SELINUX_RPM_REPO to the published repo directory." >&2
    exit 2
fi
if [[ -n "${LAB_GNUPGHOME:-}" && "${REPO}" == "${LAB_GNUPGHOME}"* ]]; then
    echo "Refusing to serve the private key directory." >&2
    exit 1
fi

echo "Serving ${REPO} on port ${PORT}"
echo "baseurl=http://$(hostname -f 2>/dev/null || hostname):${PORT}"
echo "gpgkey=http://$(hostname -f 2>/dev/null || hostname):${PORT}/RPM-GPG-KEY"
echo "Alternative: rsync -a ${REPO}/ user@prod:/var/www/selinux-pac/"
exec python3 -m http.server "${PORT}" --bind 0.0.0.0 --directory "${REPO}"
