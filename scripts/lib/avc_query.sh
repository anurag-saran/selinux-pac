#!/usr/bin/env bash
#
# avc_query.sh — Shared AVC counting for soak/monitor scripts.
#
set -euo pipefail

avc_epoch_to_ts() {
    local deploy_epoch="$1"
    python3 - "${deploy_epoch}" <<'PY'
import datetime, sys
deploy = datetime.datetime.fromtimestamp(int(sys.argv[1]), tz=datetime.timezone.utc).astimezone()
print(deploy.strftime("%m/%d/%Y %H:%M:%S"))
PY
}

count_domain_events_since() {
    local domain="$1"
    local since_ts="$2"

    if ! command -v ausearch >/dev/null 2>&1; then
        echo "-1"
        return 0
    fi

    local count
    count="$(ausearch --input-logs \
        -m AVC,USER_AVC,SELINUX_ERR,USER_SELINUX_ERR \
        -ts "${since_ts}" \
        --subject "${domain}" \
        --format raw 2>/dev/null | grep -c '^type=AVC' || true)"
    echo "${count:-0}"
}

# Filter raw AVC lines for generate / soak.
# Keep: manifest path hits; pathless non-file denials (name_bind, execmem);
# pathless file denials whose tcontext type belongs to this module (shopapi_log_t).
# Drop: /etc/passwd, /usr/lib/jvm, /proc, /sys — those are not app trees.
# Keep var_spool_t: shopapi /feature-spool writes /var/spool/shopapi and the
# kernel often logs name= without path=.
avc_filter_lines_by_paths() {
    local paths_csv="$1"
    local domain="${2:-}"
    local type_prefix=""
    local -a path_filters=()
    local hit p tctx ttype
    if [[ "${domain}" == *_t ]]; then
        type_prefix="${domain%_t}_"
    fi
    if [[ -n "${paths_csv}" ]]; then
        IFS=',' read -r -a path_filters <<< "${paths_csv}"
    fi
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        [[ "${line}" != type=AVC* ]] && continue
        if [[ ${#path_filters[@]} -eq 0 ]]; then
            echo "${line}"
            continue
        fi
        local hit=0 p
        for p in "${path_filters[@]}"; do
            p="${p// /}"
            if [[ -n "${p}" && "${line}" == *"${p}"* ]]; then
                hit=1
                break
            fi
        done
        if [[ "${hit}" -eq 1 ]]; then
            echo "${line}"
            continue
        fi
        tctx="${line##* tcontext=}"
        tctx="${tctx%% *}"
        ttype="$(cut -d: -f3 <<<"${tctx}")"
        case "${ttype}" in
            random_device_t|tmp_t|proc_t|proc_net_t|var_spool_t)
                echo "${line}"
                continue
                ;;
        esac
        # path= is a file-tree AVC outside the manifest — skip.
        if [[ "${line}" == *" path="* ]]; then
            continue
        fi
        # cgroupfs getattr is optional JVM telemetry; cgroup_t is often undeclared.
        if [[ "${line}" == *" tclass=filesystem"* ]]; then
            continue
        fi
        if [[ "${line}" == *" tclass=file "* || "${line}" == *" tclass=dir "* \
            || "${line}" == *" tclass=lnk_file "* || "${line}" == *" tclass=chr_file "* \
            || "${line}" == *" tclass=fifo_file "* ]]; then
            tctx="${line##* tcontext=}"
            tctx="${tctx%% *}"
            ttype="$(cut -d: -f3 <<<"${tctx}")"
            if [[ -n "${type_prefix}" && "${ttype}" == "${type_prefix}"* ]]; then
                echo "${line}"
            fi
            continue
        fi
        echo "${line}"
    done
}

# Demo reset writes this instead of truncating /var/log/audit.
demo_ausearch_since_file() {
    printf '%s\n' "${DEMO_STATE_DIR:-/var/lib/selinux-pac-demo}/ausearch-since"
}

resolve_ausearch_since() {
    local since_ts="$1"
    local marker
    marker="$(demo_ausearch_since_file)"
    if [[ "${since_ts}" == "boot" && -f "${marker}" ]]; then
        tr -d '\n' <"${marker}"
        return 0
    fi
    printf '%s' "${since_ts}"
}

fetch_domain_avc_raw() {
    local domain="$1"
    local since_ts="$2"

    if command -v ausearch >/dev/null 2>&1; then
        ausearch --input-logs \
            -m AVC,USER_AVC,SELINUX_ERR,USER_SELINUX_ERR \
            -ts "${since_ts}" \
            --subject "${domain}" \
            --format raw 2>/dev/null || true
        return 0
    fi
    if [[ -f /var/log/audit/audit.log ]]; then
        grep -E '^(type=AVC|type=SELINUX_ERR|type=USER_AVC|type=USER_SELINUX_ERR)' /var/log/audit/audit.log \
            | grep "${domain}" || true
    fi
}

# Export app-related AVC lines (same message types / --subject as monitor_avc.sh).
export_app_avcs_to_file() {
    local outfile="$1"
    local since_ts="${2:-boot}"
    local primary_domain="$3"
    local marker_bounds=0
    local backend_domain="${4:-}"
    local paths_csv="$5"

    if [[ -z "${primary_domain}" ]]; then
        echo "[ERROR] export_app_avcs_to_file: primary_domain required (manifest PRIMARY_DOMAIN)" >&2
        return 1
    fi
    if [[ -z "${paths_csv}" ]]; then
        echo "[ERROR] export_app_avcs_to_file: paths_csv required (manifest PATHS_CSV via app_manifest.py)" >&2
        return 1
    fi

    since_ts="$(resolve_ausearch_since "${since_ts}")"
    if [[ -f "$(demo_ausearch_since_file)" ]]; then
        marker_bounds=1
    fi

    mkdir -p "$(dirname "${outfile}")"
    : > "${outfile}"

    local raw=""
    raw="$(fetch_domain_avc_raw "${primary_domain}" "${since_ts}")"
    if [[ -n "${backend_domain}" && "${backend_domain}" != "${primary_domain}" ]]; then
        raw+=$'\n'
        raw+="$(fetch_domain_avc_raw "${backend_domain}" "${since_ts}")"
    fi

    local tmp
    tmp="$(mktemp)"
    if [[ -n "${raw}" ]]; then
        printf '%s\n' "${raw}" | avc_filter_lines_by_paths "${paths_csv}" "${primary_domain}" >> "${tmp}" || true
    fi

    # Always also read audit.log when no demo marker is set. UTM clock skew
    # makes ausearch -ts boot empty even when the file already has denials.
    # A reset marker means ausearch -ts already bounded the window; do not
    # pull older lines back out of audit.log. Soak counts still go through
    # monitor_avc.sh + ausearch.
    if [[ "${marker_bounds}" -eq 0 && -f /var/log/audit/audit.log ]]; then
        grep -E '^(type=AVC|type=SELINUX_ERR|type=USER_AVC|type=USER_SELINUX_ERR)' /var/log/audit/audit.log \
            | grep "${primary_domain}" \
            | avc_filter_lines_by_paths "${paths_csv}" "${primary_domain}" >> "${tmp}" || true
        if [[ -n "${backend_domain}" && "${backend_domain}" != "${primary_domain}" ]]; then
            grep -E '^(type=AVC|type=SELINUX_ERR|type=USER_AVC|type=USER_SELINUX_ERR)' /var/log/audit/audit.log \
                | grep "${backend_domain}" \
                | avc_filter_lines_by_paths "${paths_csv}" "${backend_domain}" >> "${tmp}" || true
        fi
    fi
    sort -u "${tmp}" > "${outfile}"
    rm -f "${tmp}"
}

# Domain-only AVC export for vendor tune-report (no path filter — binds/connects included).
export_vendor_domain_avcs_to_file() {
    local outfile="$1"
    local domain="$2"
    local since_ts="${3:-boot}"
    since_ts="$(resolve_ausearch_since "${since_ts}")"

    if [[ -z "${domain}" ]]; then
        echo "[ERROR] export_vendor_domain_avcs_to_file: domain required" >&2
        return 1
    fi

    mkdir -p "$(dirname "${outfile}")"
    : > "${outfile}"

    local tmp
    tmp="$(mktemp)"
    fetch_domain_avc_raw "${domain}" "${since_ts}" >> "${tmp}" || true
    if [[ ! -f "$(demo_ausearch_since_file)" && -f /var/log/audit/audit.log ]]; then
        grep -E '^(type=AVC|type=SELINUX_ERR|type=USER_AVC|type=USER_SELINUX_ERR)' /var/log/audit/audit.log \
            | grep "${domain}" >> "${tmp}" || true
    fi
    sort -u "${tmp}" > "${outfile}"
    rm -f "${tmp}"
}
