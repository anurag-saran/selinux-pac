"""
Prompt templates for AI-driven SELinux Policy-as-Code generation.
"""

from __future__ import annotations

from policy_rules import FORBIDDEN_TARGET_TYPES

_FORBIDDEN_TYPE_LIST = ", ".join(sorted(FORBIDDEN_TARGET_TYPES))

POLICY_JSON_SCHEMA = {
    "module_name": "myapp",
    "te_content": "raw .te policy source",
    "fc_content": "raw .fc file contexts source",
    "rationale": "brief explanation of allow rules",
    "pr_summary": "<markdown PR body section with required headings listed below>"
}

REFPOLICY_INTERFACES = """
Preferred refpolicy interfaces (use these instead of raw allow rules when applicable):
- init_daemon_domain(myapp_t, myapp_exec_t)
- init_daemon_domain(myapp_backend_t, myapp_backend_exec_t)
- files_type(myapp_exec_t) / files_type(myapp_var_lib_t) / files_type(myapp_log_t) / files_type(myapp_lib_t)
- logging_log_file(myapp_log_t)
- logging_send_syslog_msg(myapp_t)
- corecmd_exec_shell(myapp_t)
- miscfiles_read_generic_certs(myapp_t)
- corenet_tcp_bind_generic_node(myapp_t)
- corenet_port(myapp_port_t) and corenet_port(myapp_backend_port_t)
- Declare myapp_port_t + allow myapp_t myapp_port_t:tcp_socket name_bind (port 8888 via semanage port)
- allow myapp_t myapp_backend_port_t:tcp_socket name_connect (NOT connectto on tcp_socket)
- allow myapp_t myapp_backend_t:unix_stream_socket connectto for /run/myapp/notify.sock
"""

SYSTEM_PROMPT = """You are an expert SELinux policy author for Shift-Left Policy-as-Code workflows on RHEL.

OUTPUT FORMAT (CRITICAL):
- Respond with ONLY valid JSON. No markdown fences outside JSON values.
- Schema:
{
  "module_name": "myapp",
  "te_content": "<complete compilable .te file>",
  "fc_content": "<complete .fc file>",
  "rationale": "<brief technical explanation>",
  "pr_summary": "<markdown for PR body — MUST include these exact headings:\\n### Network Bindings\\n### File System Access\\n### Process Execution\\n### Explicit Denials Maintained>"
}

POLICY SYNTAX (CRITICAL — compilation will fail otherwise):
1. Use policy_module(myapp, MAJOR.MINOR.PATCH) at the top — NEVER bare `module myapp 1.0.1;`
2. Declare NEW types OUTSIDE require blocks: `type myapp_t;` then optional `require { type cert_t; }` for base types only
3. NEVER put custom `type myapp_*` inside require { } — require lists EXISTING base-policy types only
4. PREFER refpolicy interfaces from the list below — do NOT emit audit2allow-style raw allows to syslogd_t, shell_exec_t, cert_t when an interface exists
5. FORBIDDEN: allow myapp_t *:* * *; allow myapp_t self:* *; wildcard object types; allow ... bin_t:file execute
6. FORBIDDEN: allow myapp_t unreserved_port_t:tcp_socket name_bind (use myapp_port_t + corenet_port instead)
7. FORBIDDEN: allow myapp_t myapp_backend_t:tcp_socket connectto (use name_connect to myapp_backend_port_t)
8. TCP client to backend: `allow myapp_t myapp_backend_port_t:tcp_socket name_connect;`
9. Remove dead require blocks and no-op domain_auto_trans to same domain

""" + REFPOLICY_INTERFACES + """

LEAST PRIVILEGE:
- Grant ONLY permissions required by supplied AVC denials
- Add allow rules ONLY for rows under "Net-new access needs" in the user prompt
- Do NOT duplicate rules already listed under "Already covered by existing policy"
- Narrow venv labeling: only /opt/myapp/venv/bin/python[0-9.]* is myapp_exec_t; rest is myapp_lib_t

PR_SUMMARY FORMAT (pr_summary field — required headings):
### Network Bindings
- myapp_port_t TCP 8888; myapp_backend_port_t TCP 8889; Unix /run/myapp/notify.sock

### File System Access
- /var/lib/myapp state (myapp_var_lib_t); logs (myapp_log_t) under /var/log/myapp; /run/myapp (myapp_var_run_t)

### Process Execution
- init_daemon_domain transitions; backup.sh via execute_no_trans on myapp_script_exec_t

### Explicit Denials Maintained
- no """ + _FORBIDDEN_TYPE_LIST + """, wildcard allows, bin_t execute, unreserved_port_t bind

FILE CONTEXTS (fc_content) — FHS paths, NO `--` file-type suffix on directories:
- Prefer ONE directory regex per tree (e.g. /var/lib/myapp(/.*)? for all state files). Do NOT add a separate line per file when the directory pattern already assigns the correct type — mislabeled files need restorecon, not new .fc lines.
/opt/myapp                                 gen_context(system_u:object_r:myapp_exec_t,s0)
/opt/myapp/app\\.py                         gen_context(system_u:object_r:myapp_exec_t,s0)
/opt/myapp/backend_stub\\.py                gen_context(system_u:object_r:myapp_backend_exec_t,s0)
/opt/myapp/bin(/.*)?                       gen_context(system_u:object_r:myapp_script_exec_t,s0)
/opt/myapp/venv/bin/python[0-9.]*           gen_context(system_u:object_r:myapp_exec_t,s0)
/opt/myapp/venv(/.*)?                       gen_context(system_u:object_r:myapp_lib_t,s0)
/var/lib/myapp(/.*)?                        gen_context(system_u:object_r:myapp_var_lib_t,s0)
/var/log/myapp(/.*)?                        gen_context(system_u:object_r:myapp_log_t,s0)
/var/log/myapp/.*\\.log(\\.[0-9]+)?(\\.gz)? gen_context(system_u:object_r:myapp_log_t,s0)
/run/myapp(/.*)?                            gen_context(system_u:object_r:myapp_var_run_t,s0)
"""

USER_PROMPT_TEMPLATE = """Update the SELinux policy module for this application.

## Application Context
- Service: Order Processor App (example systemd unit myapp.service)
- Domain: {domain}
- User: myapp
- Install: /opt/myapp (venv at /opt/myapp/venv)
- Data: /var/lib/myapp (StateDirectory=myapp)
- Logs: /var/log/myapp (LogsDirectory=myapp; myapp_log_t + logging_log_filetrans)
- Runtime socket: /run/myapp/notify.sock (RuntimeDirectory=myapp; RuntimeDirectoryPreserve=yes)
- Script: /opt/myapp/bin/backup.sh (bash builtins only — no /usr/bin/* helpers)
- Backend: myapp-backend.service on 127.0.0.1:8889 + /run/myapp/notify.sock (domain myapp_backend_t)
- Listen: 0.0.0.0:8888 via myapp_port_t (semanage port -a -t myapp_port_t -p tcp 8888)

## Endpoints / triggers
- GET /save-log — append /var/log/myapp/data.log (myapp_log_t)
- GET /run-script — execute backup.sh
- GET /rotate-log — simulate logrotate (rename/create under myapp_log_t)
- GET /probe-backend — outbound TCP client to 127.0.0.1:8889
- GET /notify-socket — Unix stream client to /run/myapp/notify.sock
- Process start — bind TCP 8888

## Target module version
policy_module({app_name}, {version})

## Existing Type Enforcement (extend, do not discard types)
```te
{existing_te}
```

## Existing File Contexts
```fc
{existing_fc}
```

## Access needs derived from AVCs
{avc_logs}

Use the structured tables above:
- **Net-new access needs** — add or extend allow rules for these permissions only
- **Already covered** — confirm existing policy; do not duplicate these allows
- If stats show no_changes_needed, return existing te_content unchanged with minimal rationale
- If stats show fallback_merged, treat all merged rows as candidates but still avoid duplicating existing .te rules

Produce JSON with updated te_content (full file, version {version}), fc_content, rationale, and pr_summary markdown."""

FIX_PROMPT_TEMPLATE = """The SELinux policy below failed compilation.

## Compiler error
```
{compile_error}
```

## Current te_content
```te
{te_content}
```

Fix syntax ONLY. Return JSON with corrected te_content, fc_content (unchanged unless needed), rationale, pr_summary.
Use policy_module({app_name}, {version}). Declare types OUTSIDE require blocks. Prefer refpolicy interfaces. No invalid macros."""


def build_user_prompt(
    domain: str,
    avc_logs: str,
    *,
    app_name: str,
    version: str,
    existing_te: str,
    existing_fc: str,
) -> str:
    if not avc_logs.strip():
        avc_logs = "(No AVC lines — infer minimal allows from application context above.)"
    return USER_PROMPT_TEMPLATE.format(
        domain=domain,
        app_name=app_name,
        version=version,
        existing_te=existing_te.strip() or "(none)",
        existing_fc=existing_fc.strip() or "(none)",
        avc_logs=avc_logs.strip(),
    )


def build_fix_prompt(
    te_content: str,
    compile_error: str,
    *,
    app_name: str,
    version: str,
) -> str:
    return FIX_PROMPT_TEMPLATE.format(
        te_content=te_content,
        compile_error=compile_error.strip(),
        app_name=app_name,
        version=version,
    )
