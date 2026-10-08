#!/usr/bin/env python3
"""
selinux_gen.py — Shift-Left SELinux Policy-as-Code CLI.

Parses audit logs, merges with existing .te/.fc, calls LLM, bumps version,
writes pr_summary.md, and optionally compiles/installs policy.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))

from policy_rules import FORBIDDEN_TARGET_TYPES  # noqa: E402

try:
    from dotenv import load_dotenv

    load_dotenv()
except ImportError:
    pass

from prompt_templates import (  # noqa: E402
    SYSTEM_PROMPT,
    build_fix_prompt,
    build_user_prompt,
)
from fc_labeling import strip_redundant_fc_lines  # noqa: E402
from pr_summary_common import (  # noqa: E402
    PR_SUMMARY_REQUIRED_HEADINGS,
    validate_pr_summary,
)

DEFAULT_APP_NAME = "myapp"
DEFAULT_DOMAIN = "myapp_t"
DEFAULT_MODEL = "gpt-4o-mini"
DEFAULT_OUTPUT_DIR = "policy_out"
AUDIT_LOG = Path("/var/log/audit/audit.log")
PROJECT_ROOT = Path(__file__).resolve().parent.parent
SELINUX_DIR = PROJECT_ROOT / "selinux"
VERSION_FILE = SELINUX_DIR / "policy_version.txt"

REQUIRED_COMMANDS = {
    "ausearch": "audit",
    "checkmodule": "checkpolicy",
    "semodule_package": "checkpolicy",
    "semodule": "policycoreutils",
    "restorecon": "policycoreutils",
}

FORBIDDEN_TE_PATTERNS = [
    re.compile(r"allow\s+\w+\s+\*:"),
    re.compile(r"allow\s+\w+\s+\w+:\*\s"),
    re.compile(r"allow\s+\w+\s+\*:\*\s+\*\s+\*"),
    re.compile(r"allow\s+\w+\s+self:\*"),
    re.compile(r"allow\s+\w+\s+bin_t:file\s+\{[^}]*\bexecute"),
]

INVALID_REQUIRE_TYPE = re.compile(r"require\s*\{[^}]*\btype\s+myapp_", re.DOTALL)

FORBIDDEN_PRIVILEGED_TYPES = FORBIDDEN_TARGET_TYPES


@dataclass
class AvcEntry:
    raw_line: str
    scontext: str = ""
    tcontext: str = ""
    tclass: str = ""
    perm: str = ""

    @property
    def key(self) -> tuple[str, str, str, str]:
        return (self.scontext, self.tcontext, self.tclass, self.perm)


def eprint(message: str) -> None:
    print(message, file=sys.stderr)


def domain_for_app(app_name: str) -> str:
    return f"{app_name}_t"


def parse_version(text: str) -> tuple[int, int, int]:
    parts = text.strip().split(".")
    if len(parts) != 3:
        raise ValueError(f"Invalid semver: {text!r}")
    return int(parts[0]), int(parts[1]), int(parts[2])


def format_version(major: int, minor: int, patch: int) -> str:
    return f"{major}.{minor}.{patch}"


def read_policy_version(version_file: Path) -> str:
    if version_file.is_file():
        return version_file.read_text(encoding="utf-8").strip()
    return "1.0.0"


def bump_policy_version(version_file: Path) -> str:
    major, minor, patch = parse_version(read_policy_version(version_file))
    patch += 1
    new_version = format_version(major, minor, patch)
    version_file.parent.mkdir(parents=True, exist_ok=True)
    version_file.write_text(new_version + "\n", encoding="utf-8")
    return new_version


def resolve_target_version(args: argparse.Namespace, version_file: Path) -> str:
    if args.bump_version:
        return bump_policy_version(version_file)
    if args.module_version:
        return args.module_version
    te_path = args.existing_te
    if te_path.is_file():
        match = re.search(r"policy_module\(\w+,\s*([\d.]+)\)", te_path.read_text(encoding="utf-8"))
        if match:
            return match.group(1)
    return read_policy_version(version_file)


def require_commands(
    commands: dict[str, str],
    *,
    apply_mode: bool,
    compile_mode: bool,
    extract_from_host: bool,
) -> None:
    if apply_mode and os.geteuid() != 0:
        eprint("Error: --apply requires root privileges (run with sudo).")
        sys.exit(1)

    missing: list[str] = []
    if extract_from_host and shutil.which("ausearch") is None and not AUDIT_LOG.is_file():
        missing.append(f"  ausearch (dnf install audit) or readable {AUDIT_LOG}")

    if compile_mode or apply_mode:
        for cmd, pkg in commands.items():
            if cmd == "ausearch":
                continue
            if shutil.which(cmd) is None:
                missing.append(f"  {cmd} (dnf install {pkg})")

    if missing:
        eprint("Missing required commands:")
        eprint("\n".join(missing))
        sys.exit(1)


def run_command(
    args: Sequence[str],
    *,
    check: bool = True,
    capture: bool = True,
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(list(args), check=False, capture_output=capture, text=True)
    except FileNotFoundError as exc:
        raise RuntimeError(f"Command not found: {args[0]}") from exc

    if check and result.returncode != 0:
        stderr = result.stderr.strip() if result.stderr else "(no stderr)"
        stdout = result.stdout.strip() if result.stdout else "(no stdout)"
        raise RuntimeError(
            f"Command failed ({result.returncode}): {' '.join(args)}\n"
            f"stdout: {stdout}\nstderr: {stderr}"
        )
    return result


def parse_avc_field(line: str, field: str) -> str:
    match = re.search(rf"{field}=([^\s]+)", line)
    return match.group(1) if match else ""


def parse_avc_line(line: str) -> AvcEntry:
    perm = parse_avc_field(line, "perm")
    if not perm:
        denied_match = re.search(r"avc:\s+denied\s+\{([^}]+)\}", line)
        if denied_match:
            perm = denied_match.group(1).strip()

    return AvcEntry(
        raw_line=line.strip(),
        scontext=parse_avc_field(line, "scontext"),
        tcontext=parse_avc_field(line, "tcontext"),
        tclass=parse_avc_field(line, "tclass"),
        perm=perm,
    )


def filter_avc_entries(entries: list[AvcEntry], domain: str) -> list[AvcEntry]:
    filtered: list[AvcEntry] = []
    for entry in entries:
        if domain in entry.scontext or domain in entry.raw_line:
            filtered.append(entry)
            continue
        if "/opt/myapp" in entry.raw_line or "/var/lib/myapp" in entry.raw_line or "/run/myapp" in entry.raw_line:
            filtered.append(entry)
            continue
        if 'comm="python' in entry.raw_line and "myapp" in entry.raw_line:
            filtered.append(entry)
    return filtered


def deduplicate_avc_entries(entries: list[AvcEntry]) -> list[AvcEntry]:
    seen: set[tuple[str, str, str, str]] = set()
    unique: list[AvcEntry] = []
    for entry in entries:
        if entry.key in seen:
            continue
        seen.add(entry.key)
        unique.append(entry)
    return unique


def filter_prompt_avc_entries(entries: list[AvcEntry], domain: str) -> list[AvcEntry]:
    relevant: list[AvcEntry] = []
    for entry in entries:
        if domain not in entry.scontext:
            continue
        if any(
            token in entry.tcontext
            for token in (
                "myapp_var_lib_t",
                "myapp_script_exec_t",
                "myapp_exec_t",
                "port_t",
                "node_t",
                "name_t",
            )
        ):
            relevant.append(entry)
            continue
        if entry.tclass in ("tcp_socket", "udp_socket") or "name_bind" in entry.perm:
            relevant.append(entry)
            continue
        if entry.tclass == "file" and any(
            perm in entry.perm
            for perm in ("write", "append", "create", "execute", "execute_no_trans", "open", "read", "rename", "unlink")
        ):
            relevant.append(entry)
            continue
        if entry.tclass == "dir" and any(
            perm in entry.perm for perm in ("search", "write", "add_name", "create", "rename", "rmdir", "unlink")
        ):
            relevant.append(entry)
    return relevant


def format_avc_summary(entries: list[AvcEntry]) -> str:
    return "\n".join(
        f"- scontext={e.scontext} tcontext={e.tcontext} tclass={e.tclass} perm={{{e.perm}}}"
        for e in entries
    )


def load_avc_logs_from_file(
    path: Path,
    domain: str,
    *,
    existing_te: str = "",
    use_preprocess: bool = True,
    summary_path: Path | None = None,
) -> str:
    if not path.is_file():
        raise RuntimeError(f"Audit log not found: {path}")

    entries: list[AvcEntry] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "type=AVC" in line:
            entries.append(parse_avc_line(line))

    if use_preprocess:
        from avc_preprocess import build_llm_avc_summary

        entries = filter_avc_entries(entries, domain)
        entries = filter_prompt_avc_entries(entries, domain)
        if not entries:
            eprint(f"Warning: No AVC entries in {path} for {domain}")
            return ""

        summary, stats = build_llm_avc_summary(entries, existing_te=existing_te)
        if summary_path is not None:
            summary_path.parent.mkdir(parents=True, exist_ok=True)
            summary_path.write_text(summary + "\n", encoding="utf-8")
            print(f"Wrote {summary_path}")
        print(
            "AVC preprocess: "
            f"raw={stats['raw']} merged={stats['merged']} net_new={stats['net_new']}"
        )
        if stats.get("fallback_merged"):
            eprint("Warning: No net-new needs after subtracting existing .te; using merged AVC set")
        if stats.get("no_changes_needed"):
            eprint("Note: All merged AVC permissions appear covered — LLM should make minimal or no changes")
        return summary

    entries = filter_avc_entries(entries, domain)
    entries = deduplicate_avc_entries(entries)
    entries = filter_prompt_avc_entries(entries, domain)

    if not entries:
        eprint(f"Warning: No AVC entries in {path} for {domain}")
        return ""
    return format_avc_summary(entries)


def extract_avc_logs(
    domain: str,
    since: str,
    audit_log: Path | None,
    *,
    existing_te: str = "",
    use_preprocess: bool = True,
    summary_path: Path | None = None,
) -> str:
    if audit_log is not None:
        print(f"Loading AVC logs from {audit_log}...")
        return load_avc_logs_from_file(
            audit_log,
            domain,
            existing_te=existing_te,
            use_preprocess=use_preprocess,
            summary_path=summary_path,
        )

    entries: list[AvcEntry] = []
    if shutil.which("ausearch"):
        result = run_command(["ausearch", "-m", "avc", "-ts", since, "--raw"], check=False)
        if result.returncode == 0 and result.stdout:
            for line in result.stdout.splitlines():
                if "type=AVC" in line:
                    entries.append(parse_avc_line(line))

    if not entries and AUDIT_LOG.is_file():
        for line in AUDIT_LOG.read_text(encoding="utf-8", errors="replace").splitlines():
            if "type=AVC" in line:
                entries.append(parse_avc_line(line))

    if use_preprocess:
        from avc_preprocess import build_llm_avc_summary

        entries = filter_avc_entries(entries, domain)
        entries = filter_prompt_avc_entries(entries, domain)
        if not entries:
            eprint(f"Warning: No AVC entries for domain '{domain}'")
            return ""

        summary, stats = build_llm_avc_summary(entries, existing_te=existing_te)
        if summary_path is not None:
            summary_path.parent.mkdir(parents=True, exist_ok=True)
            summary_path.write_text(summary + "\n", encoding="utf-8")
            print(f"Wrote {summary_path}")
        print(
            "AVC preprocess: "
            f"raw={stats['raw']} merged={stats['merged']} net_new={stats['net_new']}"
        )
        if stats.get("fallback_merged"):
            eprint("Warning: No net-new needs after subtracting existing .te; using merged AVC set")
        if stats.get("no_changes_needed"):
            eprint("Note: All merged AVC permissions appear covered — LLM should make minimal or no changes")
        return summary

    entries = filter_avc_entries(entries, domain)
    entries = deduplicate_avc_entries(entries)
    entries = filter_prompt_avc_entries(entries, domain)

    if not entries:
        eprint(f"Warning: No AVC entries for domain '{domain}'")
        return ""
    return format_avc_summary(entries)


def call_llm(user_prompt: str, model: str, *, system_prompt: str = SYSTEM_PROMPT) -> dict:
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        eprint("Error: OPENAI_API_KEY not set (use --api-key or export OPENAI_API_KEY).")
        sys.exit(1)

    try:
        from openai import OpenAI
    except ImportError as exc:
        eprint("Install dependencies: pip3 install -r cli/requirements.txt")
        raise SystemExit(1) from exc

    base_url = os.environ.get("OPENAI_BASE_URL") or os.environ.get("OPENAI_API_BASE")
    timeout = float(os.environ.get("OPENAI_TIMEOUT", "600"))
    client_kwargs: dict = {"api_key": api_key, "timeout": timeout}
    if base_url:
        client_kwargs["base_url"] = base_url.rstrip("/")

    client = OpenAI(**client_kwargs)
    request_kwargs: dict = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "temperature": 0.1,
        "max_tokens": 8192,
    }
    if not base_url:
        request_kwargs["response_format"] = {"type": "json_object"}
    else:
        request_kwargs["extra_body"] = {"chat_template_kwargs": {"enable_thinking": False}}

    response = client.chat.completions.create(**request_kwargs)
    content = response.choices[0].message.content
    if not content:
        raise RuntimeError("LLM returned empty content.")
    return parse_policy_json(content)


def parse_policy_json(content: str) -> dict:
    stripped = content.strip()
    if stripped.startswith("```"):
        stripped = re.sub(r"^```(?:json)?\s*", "", stripped)
        stripped = re.sub(r"\s*```$", "", stripped)

    try:
        data = json.loads(stripped)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Failed to parse LLM JSON: {exc}\nRaw:\n{content}") from exc

    for key in ("module_name", "te_content", "fc_content", "rationale", "pr_summary"):
        if key not in data or not str(data[key]).strip():
            raise RuntimeError(f"LLM response missing key: {key}")
    return data


def validate_pr_summary(pr_summary: str) -> None:
    from pr_summary_common import validate_pr_summary as _validate

    _validate(pr_summary)


def validate_policy_content(te_content: str, fc_content: str, domain: str, app_name: str) -> None:
    if "policy_module" not in te_content:
        raise RuntimeError("te_content missing policy_module() declaration.")
    if domain not in te_content:
        raise RuntimeError(f"te_content must reference domain '{domain}'.")
    if INVALID_REQUIRE_TYPE.search(te_content):
        raise RuntimeError("Custom types declared inside require block — move type declarations outside require.")

    for pattern in FORBIDDEN_TE_PATTERNS:
        if pattern.search(te_content):
            raise RuntimeError(f"Forbidden over-permissive pattern: {pattern.pattern}")

    for priv_type in FORBIDDEN_PRIVILEGED_TYPES:
        if re.search(rf"allow\s+\S+\s+{re.escape(priv_type)}:", te_content):
            raise RuntimeError(f"Forbidden allow rule targeting high-privilege type: {priv_type}")

    if re.search(r"allow\s+\S+\s+var_t:file\s+\{[^}]*\bwrite\b", te_content):
        raise RuntimeError("Forbidden broad var_t:file write — use dedicated application types.")

    for token in (f"/opt/{app_name}", "/var/lib/myapp", f"{app_name}_exec_t", f"{app_name}_var_lib_t"):
        if token not in fc_content and token.replace(f"/opt/{app_name}", "/opt/myapp") not in fc_content:
            if "/opt/myapp" not in fc_content or "/var/lib/myapp" not in fc_content:
                raise RuntimeError(f"fc_content missing expected path/type near: {token}")


def write_policy_outputs(
    output_dir: Path,
    module_name: str,
    policy_data: dict,
    *,
    version_file: Path | None,
    bumped: bool,
) -> tuple[Path, Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    te_path = output_dir / f"{module_name}.te"
    fc_path = output_dir / f"{module_name}.fc"
    pr_path = output_dir / "pr_summary.md"

    te_path.write_text(str(policy_data["te_content"]).strip() + "\n", encoding="utf-8")
    fc_path.write_text(str(policy_data["fc_content"]).strip() + "\n", encoding="utf-8")
    pr_path.write_text(str(policy_data["pr_summary"]).strip() + "\n", encoding="utf-8")

    print(f"Wrote {te_path}")
    print(f"Wrote {fc_path}")
    print(f"Wrote {pr_path}")

    if bumped and version_file:
        match = re.search(r"policy_module\(\w+,\s*([\d.]+)\)", te_path.read_text(encoding="utf-8"))
        if match:
            version_file.write_text(match.group(1) + "\n", encoding="utf-8")

    return te_path, fc_path, pr_path


def has_selinux_devel() -> bool:
    return Path("/usr/share/selinux/devel/Makefile").is_file()


def compile_policy(te_path: Path, fc_path: Path, output_dir: Path, module_name: str) -> Path:
    pp_path = output_dir / f"{module_name}.pp"
    mod_path = output_dir / f"{module_name}.mod"
    for artifact in (pp_path, mod_path):
        if artifact.is_file():
            artifact.unlink()

    if has_selinux_devel():
        work_dir = output_dir / "native_build"
        work_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(te_path, work_dir / te_path.name)
        shutil.copy2(fc_path, work_dir / fc_path.name)
        run_command(
            [
                "make", "-C", str(work_dir),
                "-f", "/usr/share/selinux/devel/Makefile",
                f"{module_name}.pp",
            ]
        )
        shutil.copy2(work_dir / f"{module_name}.pp", pp_path)
        return pp_path
    raise RuntimeError("Install selinux-policy-devel (dnf install selinux-policy-devel). Compile on rhel-dev, not macOS.")


def try_compile(te_path: Path, fc_path: Path, output_dir: Path, module_name: str) -> None:
    compile_policy(te_path, fc_path, output_dir, module_name)


def generate_with_compile_retry(
    user_prompt: str,
    model: str,
    *,
    app_name: str,
    version: str,
    output_dir: Path,
    module_name: str,
    domain: str,
    max_attempts: int = 3,
    validate_compile: bool,
) -> dict:
    prompt = user_prompt
    last_error = ""
    policy_data: dict | None = None

    for attempt in range(1, max_attempts + 1):
        print(f"LLM generation attempt {attempt}/{max_attempts}...")
        policy_data = call_llm(prompt, model)
        validate_policy_content(
            str(policy_data["te_content"]),
            str(policy_data["fc_content"]),
            domain,
            app_name,
        )
        validate_pr_summary(str(policy_data["pr_summary"]))

        if not validate_compile:
            return policy_data

        te_path = output_dir / f"{module_name}.te"
        fc_path = output_dir / f"{module_name}.fc"
        te_path.write_text(str(policy_data["te_content"]).strip() + "\n", encoding="utf-8")
        fc_path.write_text(str(policy_data["fc_content"]).strip() + "\n", encoding="utf-8")

        try:
            try_compile(te_path, fc_path, output_dir, module_name)
            return policy_data
        except RuntimeError as exc:
            last_error = str(exc)
            eprint(f"Compile failed (attempt {attempt}): {last_error}")
            if attempt >= max_attempts:
                break
            prompt = build_fix_prompt(
                str(policy_data["te_content"]),
                last_error,
                app_name=app_name,
                version=version,
            )

    raise RuntimeError(f"Policy generation failed after {max_attempts} attempts.\nLast error:\n{last_error}")


def install_policy(pp_path: Path, domain: str, module_name: str) -> None:
    listed = run_command(["semodule", "-l"], check=False)
    if module_name in (listed.stdout or ""):
        run_command(["semodule", "-r", module_name], check=False)
    run_command(["semodule", "-i", str(pp_path)])

    if shutil.which("semanage"):
        result = run_command(["semanage", "permissive", "-l"], check=False)
        if domain in (result.stdout or ""):
            run_command(["semanage", "permissive", "-d", domain], check=False)

    run_command(["restorecon", "-Rv", "/opt/myapp", "/var/lib/myapp", "/var/log/myapp", "/run/myapp", "/var/opt/myapp"], check=False)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Shift-Left SELinux Policy-as-Code generator.")
    parser.add_argument("--app-name", default=DEFAULT_APP_NAME, help="Module name prefix (default: myapp)")
    parser.add_argument("--domain", default=None, help="SELinux domain filter (default: <app-name>_t)")
    parser.add_argument("--audit-log", type=Path, dest="audit_log", help="AVC audit log file")
    parser.add_argument("--avc-file", type=Path, help="Alias for --audit-log")
    parser.add_argument(
        "--existing-te",
        type=Path,
        default=SELINUX_DIR / "myapp.te",
        help="Existing .te to extend",
    )
    parser.add_argument(
        "--existing-fc",
        type=Path,
        default=SELINUX_DIR / "myapp.fc",
        help="Existing .fc to extend",
    )
    parser.add_argument("--bump-version", action="store_true", help="Increment selinux/policy_version.txt patch")
    parser.add_argument("--module-version", help="Override target module version string")
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--api-model", default=os.environ.get("OPENAI_API_MODEL", DEFAULT_MODEL))
    parser.add_argument("--api-key", help="OpenAI/LiteLLM API key (or set OPENAI_API_KEY)")
    parser.add_argument("--since", default="recent", help="ausearch window when reading live logs")
    parser.add_argument("--generate-only", action="store_true", help="Write .te/.fc/pr_summary only")
    parser.add_argument("--validate-compile", action="store_true", help="Compile-check output (needs selinux-policy-devel)")
    parser.add_argument("--dry-run", action="store_true", help="Compile but do not install")
    parser.add_argument("--apply", action="store_true", help="Compile and semodule -i (requires root)")
    parser.add_argument("--max-retries", type=int, default=3, help="LLM compile-retry attempts")
    parser.add_argument(
        "--no-avc-preprocess",
        action="store_true",
        help="Send legacy compact AVC bullets instead of structured avc_summary",
    )
    parser.add_argument(
        "--write-avc-summary",
        type=Path,
        default=None,
        help="Write structured AVC summary (default: <output-dir>/avc_summary.txt)",
    )
    parser.add_argument(
        "--legacy-full-policy",
        action="store_true",
        help="Deprecated: LLM generates full .te/.fc (use dev_generate_policy.sh + summarize_pr.py)",
    )
    return parser


def main() -> int:
    parser = build_arg_parser()
    args = parser.parse_args()

    if not args.legacy_full_policy:
        eprint(
            "selinux_gen.py: full LLM policy generation is deprecated.\n"
            "  Policy:  bash scripts/dev_generate_policy.sh   (deterministic, default)\n"
            "  Summary: python3 cli/summarize_pr.py         (optional LLM prose)\n"
            "  Or pass --legacy-full-policy to run the old all-in-one LLM path."
        )
        return 2

    if args.api_key:
        os.environ["OPENAI_API_KEY"] = args.api_key

    if args.generate_only and args.apply:
        eprint("Use either --generate-only or --apply, not both.")
        return 1

    app_name = args.app_name
    domain = args.domain or domain_for_app(app_name)
    audit_log = args.audit_log or args.avc_file
    output_dir = Path(args.output_dir).resolve()
    version_file = SELINUX_DIR / "policy_version.txt"

    apply_mode = args.apply and not args.dry_run and not args.generate_only
    compile_mode = args.apply or args.dry_run or args.validate_compile
    extract_from_host = audit_log is None

    require_commands(
        REQUIRED_COMMANDS,
        apply_mode=apply_mode,
        compile_mode=compile_mode and not args.generate_only,
        extract_from_host=extract_from_host,
    )

    target_version = resolve_target_version(args, version_file)
    existing_te = args.existing_te.read_text(encoding="utf-8") if args.existing_te.is_file() else ""
    existing_fc = args.existing_fc.read_text(encoding="utf-8") if args.existing_fc.is_file() else ""

    use_preprocess = not args.no_avc_preprocess
    avc_summary_path = args.write_avc_summary
    if use_preprocess and avc_summary_path is None:
        avc_summary_path = output_dir / "avc_summary.txt"

    avc_logs = extract_avc_logs(
        domain,
        args.since,
        audit_log,
        existing_te=existing_te,
        use_preprocess=use_preprocess,
        summary_path=avc_summary_path if use_preprocess else None,
    )
    user_prompt = build_user_prompt(
        domain,
        avc_logs,
        app_name=app_name,
        version=target_version,
        existing_te=existing_te,
        existing_fc=existing_fc,
    )

    validate_compile = args.validate_compile or apply_mode or args.dry_run
    if args.generate_only and not args.validate_compile:
        validate_compile = Path("/usr/share/selinux/devel/Makefile").is_file()

    print(f"Calling model '{args.api_model}' (target version {target_version})...")
    policy_data = generate_with_compile_retry(
        user_prompt,
        args.api_model,
        app_name=app_name,
        version=target_version,
        output_dir=output_dir,
        module_name=app_name,
        domain=domain,
        max_attempts=args.max_retries,
        validate_compile=validate_compile,
    )

    if existing_fc.strip():
        before = str(policy_data["fc_content"])
        policy_data["fc_content"] = strip_redundant_fc_lines(existing_fc, before)
        if policy_data["fc_content"].strip() != before.strip():
            print("Stripped redundant .fc lines (label drift — use restorecon, not per-file entries).")

    print("\n--- Rationale ---")
    print(policy_data["rationale"])
    print("---\n")

    write_policy_outputs(
        output_dir,
        app_name,
        policy_data,
        version_file=version_file,
        bumped=args.bump_version,
    )

    if args.generate_only:
        print("\nGenerate-only complete. Review policy_out/ then apply on SELinux host.")
        return 0

    te_path = output_dir / f"{app_name}.te"
    fc_path = output_dir / f"{app_name}.fc"
    try:
        pp_path = compile_policy(te_path, fc_path, output_dir, app_name)
    except RuntimeError as exc:
        eprint(f"Compilation failed: {exc}")
        return 1

    if apply_mode:
        try:
            install_policy(pp_path, domain, app_name)
        except RuntimeError as exc:
            eprint(f"Install failed: {exc}")
            return 1
        print("Policy applied successfully.")

    elif args.dry_run:
        print(f"Dry run complete: {pp_path}")
    else:
        print(f"Compiled: {pp_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
