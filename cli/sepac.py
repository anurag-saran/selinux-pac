#!/usr/bin/env python3
"""sepac — single admin CLI for selinux-pac.

Phase 1: front door that wraps existing scripts. The scripts stay the engine.
Python 3.9 (RHEL 9 python3). No new dependencies.
"""
from __future__ import annotations

import argparse
import configparser
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, List, Optional, Sequence

# ── Tool tree (code: cli/, scripts/) ─────────────────────────────────────────

_SELF = Path(__file__).resolve()
# When installed: /usr/share/selinux-pac/cli/sepac.py → tool tree = /usr/share/selinux-pac
# In a checkout: cli/sepac.py → tool tree = the repo root
TOOL_TREE = _SELF.parent.parent
SCRIPTS = TOOL_TREE / "scripts"

# ── Policy tree (config/, selinux/, ansible/) ─────────────────────────────────

_SEPAC_CONF = Path(os.environ.get("SEPAC_CONF", "/etc/selinux-pac/sepac.conf"))


def _read_conf_tree() -> str:
    """Read tree= from /etc/selinux-pac/sepac.conf."""
    if not _SEPAC_CONF.is_file():
        return ""
    cp = configparser.ConfigParser()
    try:
        with open(_SEPAC_CONF, encoding="utf-8") as fh:
            # sepac.conf has no section headers; inject one
            cp.read_string("[sepac]\n" + fh.read())
        return cp.get("sepac", "tree", fallback="").strip()
    except (configparser.Error, OSError):
        return ""


def _git_toplevel(d: Path) -> str:
    """Return git top-level of *d*, or '' on failure."""
    try:
        r = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=str(d),
            capture_output=True,
            text=True,
        )
        return r.stdout.strip() if r.returncode == 0 else ""
    except (FileNotFoundError, OSError):
        return ""


def _is_policy_tree(d: str) -> bool:
    p = Path(d)
    return (p / "config").is_dir() and (p / "selinux").is_dir()


def resolve_policy_tree(cli_tree: str | None) -> Path | None:
    """Resolve the policy tree. Returns None when no policy tree is found."""
    # 1. --tree DIR
    if cli_tree:
        p = Path(cli_tree)
        if _is_policy_tree(str(p)):
            return p
        return None
    # 2. git top-level of cwd, if it has config/ and selinux/
    top = _git_toplevel(Path.cwd())
    if top and _is_policy_tree(top):
        return Path(top)
    # 3. tree= in sepac.conf
    conf_tree = _read_conf_tree()
    if conf_tree and _is_policy_tree(conf_tree):
        return Path(conf_tree)
    return None


# These are resolved lazily, after argument parsing
POLICY_TREE: Path | None = None
# Backward compatibility: REPO_ROOT still works for commands in a checkout
REPO_ROOT = TOOL_TREE


def _require_policy_tree(args: argparse.Namespace) -> Path:
    """Return the policy tree or exit."""
    global POLICY_TREE
    if POLICY_TREE is None:
        POLICY_TREE = resolve_policy_tree(getattr(args, "tree", None))
    if POLICY_TREE is None:
        print(
            "No policy tree found (need config/ and selinux/).\n"
            "Run from a selinux-pac checkout, pass --tree DIR, or set tree= in "
            f"{_SEPAC_CONF}",
            file=sys.stderr,
        )
        raise SystemExit(2)
    return POLICY_TREE


def _init_trees(args: argparse.Namespace) -> None:
    """Resolve policy tree and update globals. Called once from main()."""
    global POLICY_TREE, REPO_ROOT, ANSIBLE
    POLICY_TREE = resolve_policy_tree(getattr(args, "tree", None))
    if POLICY_TREE is not None:
        REPO_ROOT = POLICY_TREE
    ANSIBLE = REPO_ROOT / "ansible"

# ── Manifest helper (reuse existing code) ────────────────────────────────────

sys.path.insert(0, str(SCRIPTS / "lib"))
from app_manifest import (  # noqa: E402
    load_manifest,
    normalize,
    load_raw,
    policy_source_paths,
)

# ── Constants ────────────────────────────────────────────────────────────────

APP_RE = re.compile(r"^[a-z][a-z0-9_]{0,40}$")
PERM_RE = re.compile(r"^[a-z_]+$")
ROLE_FILE = os.environ.get("SEPAC_ROLE_FILE", "/etc/selinux-pac/role")
ANSIBLE = TOOL_TREE / "ansible"  # updated by _init_trees()


# ── Version ──────────────────────────────────────────────────────────────────

def _sepac_version() -> str:
    """RPM version when installed, git describe in a checkout."""
    try:
        r = subprocess.run(
            ["rpm", "-q", "--qf", "%{VERSION}-%{RELEASE}", "selinux-pac"],
            capture_output=True, text=True,
        )
        if r.returncode == 0 and r.stdout and "not installed" not in r.stdout:
            return r.stdout.strip()
    except FileNotFoundError:
        pass
    try:
        r = subprocess.run(
            ["git", "describe", "--tags", "--always", "--dirty"],
            cwd=str(TOOL_TREE),
            capture_output=True, text=True,
        )
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except (FileNotFoundError, OSError):
        pass
    return "unknown"

DIM = "\033[2m"
NC = "\033[0m"

# Triage advice lines keyed by situation.
TRIAGE_ADVICE = {
    "none": "No Red Hat policy for {app}. Write one: sepac generate {app}",
    "loaded": "Red Hat policy confines {app}. Tune it, do not write a module: sepac tune {app}",
    "loaded_unconfined": (
        "Red Hat module loaded, but {domain} is unconfined. "
        "Install the vendor's confining package. Generate only with --force \"reason\"."
    ),
    "package_installed": "Vendor SELinux package {pkg} is installed but not loaded. Enable it first.",
    "package_available": "Vendor SELinux package {pkg} is available. Install it first.",
    "base_policy": "Base policy covers {app}. Tune it: sepac tune {app}",
    "unconfined": "{app} runs unconfined ({domain}). Install the vendor package first.",
}


# ── Utilities ────────────────────────────────────────────────────────────────

def _validate_app(app: str) -> None:
    if not APP_RE.match(app):
        print(f"Invalid app name: {app!r} (must match {APP_RE.pattern})", file=sys.stderr)
        raise SystemExit(2)


def _validate_perm(perm: str) -> None:
    if not PERM_RE.match(perm):
        print(f"Invalid permission: {perm!r} (must match {PERM_RE.pattern})", file=sys.stderr)
        raise SystemExit(2)


def _validate_env(env: str) -> Path:
    inv = ANSIBLE / f"inventory.{env}.yml"
    if not inv.is_file():
        print(
            f"No inventory for --env {env} (looked for {inv}).\n"
            f"Create it: bash lab/setup_rhel_hosts.sh write --qa-host … --prod-host …",
            file=sys.stderr,
        )
        raise SystemExit(2)
    return inv


def _manifest_path(app: str, manifest_flag: str | None = None) -> Path:
    """Manifest lookup order: --manifest PATH → policy tree config/ → /etc/selinux-pac/apps/."""
    if manifest_flag:
        return Path(manifest_flag)
    if POLICY_TREE is not None:
        p = POLICY_TREE / "config" / f"{app}.manifest.yml"
        if p.is_file():
            return p
    etc = Path(f"/etc/selinux-pac/apps/{app}.manifest.yml")
    if etc.is_file():
        return etc
    # Return the policy-tree path even if it doesn't exist (for error messages)
    if POLICY_TREE is not None:
        return POLICY_TREE / "config" / f"{app}.manifest.yml"
    return Path(f"/etc/selinux-pac/apps/{app}.manifest.yml")


def _load_app_manifest(app: str, manifest_flag: str | None = None) -> dict[str, Any]:
    p = _manifest_path(app, manifest_flag)
    if not p.is_file():
        print(f"No manifest: {p}", file=sys.stderr)
        raise SystemExit(2)
    return load_manifest(p)


def _require_manifest(app: str, manifest_flag: str | None = None) -> dict[str, Any]:
    """For commands that strictly need a manifest (generate, check, load, status)."""
    return _load_app_manifest(app, manifest_flag)


def _app_domain(app: str, manifest: dict[str, Any] | None) -> str:
    if manifest:
        return str(manifest["domain"])
    return f"{app}_t"


def _app_unit(app: str, manifest: dict[str, Any] | None, override: str | None) -> str:
    if override:
        return override
    if manifest:
        return str(manifest["services"]["primary"]["unit"])
    return f"{app}.service"


def _module_dir(manifest: dict[str, Any]) -> Path:
    paths = policy_source_paths(REPO_ROOT, manifest)
    return paths["module_dir"]


def _need_sudo() -> bool:
    return os.geteuid() != 0


def _sudo_prefix() -> list[str]:
    return ["sudo"] if _need_sudo() else []


def _run(
    argv: list[str],
    *,
    dry_run: bool = False,
    verbose: bool = False,
    env: dict[str, str] | None = None,
    check: bool = False,
    capture: bool = False,
) -> subprocess.CompletedProcess[str]:
    if dry_run:
        print(" ".join(argv))
        return subprocess.CompletedProcess(argv, 0, "", "")
    if verbose:
        print(f"{DIM}{' '.join(argv)}{NC}", file=sys.stderr)
    run_env: dict[str, str] | None = None
    if env:
        run_env = dict(os.environ)
        run_env.update(env)
    return subprocess.run(
        argv,
        env=run_env,
        check=check,
        capture_output=capture,
        text=True,
    )


# ── Load guardrail (section 4) ──────────────────────────────────────────────

def _check_qa_role() -> None:
    """Refuse load on hosts whose role is not qa or dev."""
    role_file = Path(ROLE_FILE)
    if not role_file.is_file():
        print(
            "This host's role is not qa. Production gets policy from the signed RPM "
            "(sepac canary). On a QA host: echo qa | sudo tee /etc/selinux-pac/role",
            file=sys.stderr,
        )
        raise SystemExit(1)
    role = role_file.read_text(encoding="utf-8").strip().lower()
    if role not in ("qa", "dev"):
        print(
            f"This host's role is {role!r}, not qa. Production gets policy from the signed RPM "
            "(sepac canary). On a QA host: echo qa | sudo tee /etc/selinux-pac/role",
            file=sys.stderr,
        )
        raise SystemExit(1)


def _check_not_production() -> None:
    """Refuse generate/check/load on production hosts."""
    role_file = Path(ROLE_FILE)
    if not role_file.is_file():
        return
    role = role_file.read_text(encoding="utf-8").strip().lower()
    if role == "production":
        print(
            "This host's role is production. generate, check, and load are not "
            "available on production hosts — use sepac canary to deploy from the "
            "signed RPM.",
            file=sys.stderr,
        )
        raise SystemExit(1)


# ── Commands ─────────────────────────────────────────────────────────────────

def cmd_doctor(args: argparse.Namespace) -> int:
    argv = ["bash", str(SCRIPTS / "selinux_pac_adopt.sh"), "doctor"]
    r = _run(argv, dry_run=args.dry_run, verbose=args.verbose)
    return r.returncode


def cmd_triage(args: argparse.Namespace) -> int:
    app = args.app
    _validate_app(app)
    manifest: dict[str, Any] | None = None
    mp = _manifest_path(app, getattr(args, "manifest", None))
    if mp.is_file():
        try:
            manifest = load_manifest(mp)
        except (ValueError, OSError):
            pass
    unit = _app_unit(app, manifest, args.unit)
    domain = _app_domain(app, manifest)

    argv = [
        "bash", str(SCRIPTS / "lib" / "vendor_policy_check.sh"),
        "--report", "--app-name", app, "--unit", unit,
    ]
    r = _run(argv, dry_run=args.dry_run, verbose=args.verbose, capture=not args.dry_run)
    if args.dry_run:
        return 0
    if r.stdout:
        print(r.stdout, end="")
    if r.stderr:
        print(r.stderr, end="", file=sys.stderr)
    # Parse triage line and print advice
    for line in (r.stdout or "").splitlines():
        if "TRIAGE" not in line:
            continue
        fields: dict[str, str] = {}
        for token in line.split():
            if "=" in token:
                k, _, v = token.partition("=")
                fields[k] = v
        situation = fields.get("situation", "")
        tpl = TRIAGE_ADVICE.get(situation)
        if tpl:
            print(tpl.format(
                app=app,
                domain=fields.get("domain", domain),
                pkg=fields.get("package", ""),
            ))
        break
    return r.returncode


def cmd_tune(args: argparse.Namespace) -> int:
    app = args.app
    _validate_app(app)
    manifest: dict[str, Any] | None = None
    mp = _manifest_path(app, getattr(args, "manifest", None))
    if mp.is_file():
        try:
            manifest = load_manifest(mp)
        except (ValueError, OSError):
            pass
    unit = _app_unit(app, manifest, args.unit)
    argv = _sudo_prefix() + [
        "bash", str(SCRIPTS / "dev_generate_policy.sh"),
        "--tune-report", "--app-name", app, "--unit", unit,
        "--app-root", str(REPO_ROOT),
    ]
    r = _run(argv, dry_run=args.dry_run, verbose=args.verbose)
    return r.returncode


def cmd_denials(args: argparse.Namespace) -> int:
    app = args.app
    _validate_app(app)
    manifest: dict[str, Any] | None = None
    mp = _manifest_path(app, getattr(args, "manifest", None))
    if mp.is_file():
        try:
            manifest = load_manifest(mp)
        except (ValueError, OSError):
            pass
    domain = _app_domain(app, manifest)
    has_manifest = manifest is not None

    since_map = {
        "recent": "recent",
        "boot": "boot",
        "today": "today",
        "this-hour": "this-hour",
    }
    since = since_map.get(args.since, args.since)
    last_n = args.last

    # Build ausearch command
    ausearch_argv = _sudo_prefix() + ["ausearch", "-m", "avc", "-ts", since]
    if args.dry_run:
        desc_parts = [" ".join(ausearch_argv)]
        if has_manifest:
            desc_parts.append(f"| grep {domain}")
        else:
            desc_parts.append(f"| grep -i {app}")
        if args.enforced:
            desc_parts.append("| grep permissive=0")
        if args.why:
            desc_parts.append("| audit2why")
        desc_parts.append(f"| tail -n {last_n}")
        print(" ".join(desc_parts))
        return 0

    if args.verbose:
        print(f"{DIM}{' '.join(ausearch_argv)}{NC}", file=sys.stderr)
    r = subprocess.run(ausearch_argv, capture_output=True, text=True)
    lines = (r.stdout or "").splitlines()

    # Keep only type=AVC lines matching the domain
    kept: list[str] = []
    for line in lines:
        if "type=AVC" not in line:
            continue
        if has_manifest:
            if domain not in line:
                continue
        else:
            if app.lower() not in line.lower():
                continue
        if args.enforced and "permissive=0" not in line:
            continue
        kept.append(line)

    if not kept:
        print(f"No denials for {domain} since {since}")
        return 0

    if args.why:
        tail = kept[-last_n:]
        why_input = "\n".join(tail) + "\n"
        why_argv = ["audit2why"]
        if args.verbose:
            print(f"{DIM}| audit2why{NC}", file=sys.stderr)
        wp = subprocess.run(why_argv, input=why_input, capture_output=True, text=True)
        print(wp.stdout, end="")
        if wp.stderr:
            print(wp.stderr, end="", file=sys.stderr)
    else:
        for line in kept[-last_n:]:
            print(line)
    return 0


def cmd_generate(args: argparse.Namespace) -> int:
    _require_policy_tree(args)
    app = args.app
    _validate_app(app)
    if not args.dry_run:
        _check_not_production()
    for perm in (args.approve or []):
        _validate_perm(perm)
    manifest = _require_manifest(app, getattr(args, "manifest", None))

    argv = _sudo_prefix() + [
        "bash", str(SCRIPTS / "dev_generate_policy.sh"),
        "--app-name", app,
        "--app-root", str(REPO_ROOT),
    ]
    if args.apply:
        argv.append("--apply")
    for perm in (args.approve or []):
        argv.extend(["--allow-needs-review-perm", perm])
    if args.force:
        argv.extend(["--force", args.force])
    if args.skip_export:
        argv.append("--skip-export")
    r = _run(argv, dry_run=args.dry_run, verbose=args.verbose)

    # If blocked, show hint from findings.json
    if r.returncode != 0 and not args.dry_run:
        findings_path = REPO_ROOT / "policy_out" / "findings.json"
        if findings_path.is_file():
            try:
                data = json.loads(findings_path.read_text(encoding="utf-8"))
                if data.get("generation_blocked"):
                    needs = [
                        f for f in data.get("findings", [])
                        if f.get("verdict") == "needs_review" and not f.get("review_key")
                    ]
                    if needs:
                        perms = sorted({
                            p for f in needs for p in f.get("perms", [])
                        })
                        perm_str = " ".join(f"--approve {p}" for p in perms)
                        print(
                            f"Blocked for review: {', '.join(perms)}. "
                            f"After review: sepac generate {app} {perm_str} --apply"
                        )
            except (json.JSONDecodeError, OSError):
                pass
    return r.returncode


def cmd_check(args: argparse.Namespace) -> int:
    _require_policy_tree(args)
    app = args.app
    _validate_app(app)
    if not args.dry_run:
        _check_not_production()
    manifest = _require_manifest(app, getattr(args, "manifest", None))
    mod_dir = _module_dir(manifest)

    # 1. validate_app_manifest.sh
    mp = _manifest_path(app, getattr(args, "manifest", None))
    argv1 = ["bash", str(SCRIPTS / "validate_app_manifest.sh"), str(mp)]
    r = _run(argv1, dry_run=args.dry_run, verbose=args.verbose)
    if not args.dry_run and r.returncode != 0:
        return r.returncode

    # 2. compile_and_validate.sh
    argv2 = ["bash", str(SCRIPTS / "compile_and_validate.sh"), str(mod_dir), "--app", app]
    r = _run(argv2, dry_run=args.dry_run, verbose=args.verbose)
    if not args.dry_run and r.returncode != 0:
        return r.returncode

    # 3. validate_policy_semantics.sh
    sem_script = SCRIPTS / "validate_policy_semantics.sh"
    have_devel = (
        Path("/usr/share/selinux/devel/Makefile").is_file()
        or args.dry_run
    )
    have_setools = True
    if not args.dry_run:
        try:
            subprocess.run(["sesearch", "--version"], capture_output=True, check=True)
        except (FileNotFoundError, subprocess.CalledProcessError):
            have_setools = False
    if not have_devel or not have_setools:
        if not args.dry_run:
            print("SKIP semantics: needs selinux-policy-devel and setools-console")
            return 0

    argv3 = _sudo_prefix() + ["bash", str(sem_script), str(mod_dir), "--app", app]
    r = _run(argv3, dry_run=args.dry_run, verbose=args.verbose)
    return r.returncode if not args.dry_run else 0


def cmd_load(args: argparse.Namespace) -> int:
    _require_policy_tree(args)
    app = args.app
    _validate_app(app)
    manifest = _require_manifest(app, getattr(args, "manifest", None))

    if not args.dry_run:
        _check_qa_role()

    mod_dir = _module_dir(manifest)
    policy_out = REPO_ROOT / "policy_out"
    pp_path: Path

    # Decide which .pp to load
    out_pp = policy_out / f"{app}.pp"
    out_te = policy_out / f"{app}.te"
    out_fc = policy_out / f"{app}.fc"
    repo_te = mod_dir / f"{app}.te"
    repo_fc = mod_dir / f"{app}.fc"

    use_policy_out = False
    if out_pp.is_file() and out_te.is_file() and out_fc.is_file():
        if repo_te.is_file() and repo_fc.is_file():
            if (out_te.read_bytes() == repo_te.read_bytes()
                    and out_fc.read_bytes() == repo_fc.read_bytes()):
                use_policy_out = True

    if use_policy_out:
        pp_path = out_pp
    else:
        # Compile from MODULE_DIR
        compile_argv = ["bash", str(SCRIPTS / "compile_and_validate.sh"), str(mod_dir), "--app", app]
        r = _run(compile_argv, dry_run=args.dry_run, verbose=args.verbose,
                 capture=not args.dry_run)
        if not args.dry_run and r.returncode != 0:
            print(r.stdout, end="")
            print(r.stderr, end="", file=sys.stderr)
            return r.returncode
        pp_path = mod_dir / f"{app}.pp"

    # 1. semodule -i
    argv_load = _sudo_prefix() + ["semodule", "-i", str(pp_path)]
    r = _run(argv_load, dry_run=args.dry_run, verbose=args.verbose)
    if not args.dry_run and r.returncode != 0:
        return r.returncode

    # 2. restorecon on manifest paths
    paths_to_restore: list[str] = []
    mp = manifest["paths"]
    for key in ("install_root", "var_dir", "log_dir", "runtime_dir"):
        p = mp.get(key)
        if p and (args.dry_run or Path(p).exists()):
            paths_to_restore.append(p)
    for p in mp.get("extra_fc_roots", []):
        if p and (args.dry_run or Path(p).exists()):
            paths_to_restore.append(p)
    if paths_to_restore:
        argv_rc = _sudo_prefix() + ["restorecon", "-Rv"] + paths_to_restore
        _run(argv_rc, dry_run=args.dry_run, verbose=args.verbose)

    # 3. semanage port for each selinux_ports entry
    for port_entry in manifest.get("selinux_ports", []):
        port_num = port_entry["port"]
        proto = port_entry.get("proto", "tcp")
        ptype = port_entry["type"]
        argv_add = _sudo_prefix() + [
            "semanage", "port", "-a", "-t", ptype, "-p", proto, str(port_num),
        ]
        if args.dry_run:
            _run(argv_add, dry_run=True)
            continue
        r = subprocess.run(argv_add, capture_output=True, text=True)
        if r.returncode != 0:
            # Fall back to -m
            argv_mod = _sudo_prefix() + [
                "semanage", "port", "-m", "-t", ptype, "-p", proto, str(port_num),
            ]
            if args.verbose:
                print(f"{DIM}{' '.join(argv_mod)}{NC}", file=sys.stderr)
            rm = subprocess.run(argv_mod, capture_output=True, text=True)
            if rm.returncode != 0 and rm.stderr.strip():
                print(rm.stderr, end="", file=sys.stderr)

    # 4. Remove permissive exception (--enforce)
    if args.enforce:
        domain = str(manifest["domain"])
        argv_perm = _sudo_prefix() + ["semanage", "permissive", "-d", domain]
        r = _run(argv_perm, dry_run=args.dry_run, verbose=args.verbose)
        if not args.dry_run and r.returncode != 0:
            return r.returncode

    return 0


def cmd_status(args: argparse.Namespace) -> int:
    app = args.app
    _validate_app(app)
    manifest = _require_manifest(app, getattr(args, "manifest", None))
    domain = str(manifest["domain"])
    mod_dir = _module_dir(manifest)
    unit = str(manifest["services"]["primary"]["unit"])

    if args.dry_run:
        print("getenforce")
        print(f"semodule -lfull | grep {app}")
        print(f"semanage permissive -l | grep {domain}")
        print(f"systemctl show -p MainPID --value {unit}")
        print(f"sudo restorecon -Rn {' '.join(_restore_paths(manifest, dry=True))}")
        print(f"sudo ausearch -m avc -ts recent | grep {domain} | wc -l")
        return 0

    # 1. getenforce
    try:
        ge = subprocess.run(["getenforce"], capture_output=True, text=True)
        print(f"Host: {ge.stdout.strip()}")
    except FileNotFoundError:
        print("Host: getenforce not found")

    # 2. Module priority + version match
    version_file = mod_dir / "policy_version.txt"
    version = version_file.read_text(encoding="utf-8").strip() if version_file.is_file() else "?"
    try:
        lfull = subprocess.run(
            _sudo_prefix() + ["semodule", "-lfull"],
            capture_output=True, text=True,
        )
        matched = [l for l in lfull.stdout.splitlines() if app in l.split()]
        if matched:
            parts = matched[0].split()
            priority = parts[0] if len(parts) >= 3 else "?"
            # Check hash match
            with tempfile.TemporaryDirectory() as td:
                subprocess.run(
                    _sudo_prefix() + ["semodule", "-E", app, "-p", td],
                    capture_output=True, text=True,
                )
                extracted = Path(td) / f"{app}.pp"
                built = mod_dir / f"{app}.pp"
                if extracted.is_file() and built.is_file():
                    h1 = hashlib.sha256(extracted.read_bytes()).hexdigest()
                    h2 = hashlib.sha256(built.read_bytes()).hexdigest()
                    match_str = "matches repo" if h1 == h2 else "differs from repo"
                else:
                    match_str = "cannot compare"
            print(f"Module: priority {priority}, version {version}, {match_str}")
        else:
            print(f"Module: not loaded (version {version} in repo)")
    except FileNotFoundError:
        print(f"Module: semodule not found (version {version} in repo)")

    # 3. Permissive status
    try:
        perm = subprocess.run(
            _sudo_prefix() + ["semanage", "permissive", "-l"],
            capture_output=True, text=True,
        )
        if domain in (perm.stdout or ""):
            print(f"Domain: {domain} permissive")
        else:
            print(f"Domain: {domain} enforcing")
    except FileNotFoundError:
        print(f"Domain: semanage not found")

    # 4. Process label
    try:
        spid = subprocess.run(
            ["systemctl", "show", "-p", "MainPID", "--value", unit],
            capture_output=True, text=True,
        )
        pid = spid.stdout.strip()
        if pid and pid != "0":
            ps = subprocess.run(
                ["ps", "-o", "label=", "-p", pid],
                capture_output=True, text=True,
            )
            print(f"Process: {ps.stdout.strip()} (PID {pid})")
        else:
            print(f"Process: {unit} not running")
    except FileNotFoundError:
        print("Process: systemctl not found")

    # 5. Label check
    rpaths = _restore_paths(manifest, dry=False)
    if rpaths:
        rc_argv = _sudo_prefix() + ["restorecon", "-Rn"] + rpaths
        rc = subprocess.run(rc_argv, capture_output=True, text=True)
        diff_lines = [l for l in (rc.stdout or "").splitlines() if l.strip()]
        if diff_lines:
            print(f"Labels: {len(diff_lines)} files differ")
        else:
            print("Labels: ok")
    else:
        print("Labels: no paths to check")

    # 6. Recent denials
    aus = subprocess.run(
        _sudo_prefix() + ["ausearch", "-m", "avc", "-ts", "recent"],
        capture_output=True, text=True,
    )
    count = sum(1 for l in (aus.stdout or "").splitlines() if domain in l and "type=AVC" in l)
    print(f"Denials since recent: {count}")
    return 0


def _restore_paths(manifest: dict[str, Any], *, dry: bool) -> list[str]:
    result: list[str] = []
    mp = manifest["paths"]
    for key in ("install_root", "var_dir", "log_dir", "runtime_dir"):
        p = mp.get(key)
        if p and (dry or Path(p).exists()):
            result.append(p)
    for p in mp.get("extra_fc_roots", []):
        if p and (dry or Path(p).exists()):
            result.append(p)
    return result


# ── Ansible commands ─────────────────────────────────────────────────────────

def _ansible_limit(args: argparse.Namespace) -> list[str]:
    limit = getattr(args, "limit", None)
    return ["--limit", limit] if limit else []


def cmd_canary(args: argparse.Namespace) -> int:
    _require_policy_tree(args)
    inv = _validate_env(args.env)
    argv = [
        "ansible-playbook", "-i", str(inv),
        str(ANSIBLE / "deploy_canary.yml"),
    ] + _ansible_limit(args)
    r = _run(argv, dry_run=args.dry_run, verbose=args.verbose)
    return r.returncode


def cmd_soak(args: argparse.Namespace) -> int:
    _require_policy_tree(args)
    inv = _validate_env(args.env)
    playbook = "soak_status.yml" if args.status else "soak_monitor.yml"
    argv = [
        "ansible-playbook", "-i", str(inv),
        str(ANSIBLE / playbook),
    ] + _ansible_limit(args)
    r = _run(argv, dry_run=args.dry_run, verbose=args.verbose)
    return r.returncode


def cmd_enforce(args: argparse.Namespace) -> int:
    _require_policy_tree(args)
    if not args.ticket:
        print("--ticket is required for enforce", file=sys.stderr)
        raise SystemExit(2)
    inv = _validate_env(args.env)
    argv = [
        "ansible-playbook", "-i", str(inv),
        str(ANSIBLE / "enforce_production.yml"),
        "-e", f"change_ticket={args.ticket}",
    ]
    if args.skip_soak_days:
        argv.extend(["-e", "skip_soak_days=true"])
    if args.break_glass:
        argv.extend(["-e", "force_enforce=true", "-e", f"break_glass_reason={args.break_glass}"])
    argv += _ansible_limit(args)
    r = _run(argv, dry_run=args.dry_run, verbose=args.verbose)
    return r.returncode


def cmd_rollback(args: argparse.Namespace) -> int:
    _require_policy_tree(args)
    inv = _validate_env(args.env)
    argv = [
        "ansible-playbook", "-i", str(inv),
        str(ANSIBLE / "emergency_rollback.yml"),
    ] + _ansible_limit(args)
    r = _run(argv, dry_run=args.dry_run, verbose=args.verbose)
    return r.returncode


def cmd_build(args: argparse.Namespace) -> int:
    _require_policy_tree(args)
    argv = ["bash", str(REPO_ROOT / "packaging" / "build_rpms.sh")]
    env: dict[str, str] = {}
    if args.allow_dirty:
        env["BUILD_RPMS_ALLOW_DIRTY"] = "1"
    r = _run(argv, dry_run=args.dry_run, verbose=args.verbose, env=env if env else None)
    return r.returncode


def cmd_publish(args: argparse.Namespace) -> int:
    _require_policy_tree(args)
    env_file = Path(args.env_file)
    if not args.dry_run and not env_file.is_file():
        print(f"Env file not found: {env_file}", file=sys.stderr)
        raise SystemExit(2)
    env: dict[str, str] = {}
    if not args.dry_run and env_file.is_file():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                k, _, v = line.partition("=")
                v = v.strip().strip("'\"")
                env[k.strip()] = v
    argv = ["bash", str(REPO_ROOT / "packaging" / "publish_internal.sh")]
    r = _run(argv, dry_run=args.dry_run, verbose=args.verbose, env=env if env else None)
    return r.returncode


# ── Completion ───────────────────────────────────────────────────────────────

def cmd_completion(args: argparse.Namespace) -> int:
    """Print bash completion script generated from the argparse parser."""
    parser = build_parser()
    subcmds: list[str] = []
    subcmd_flags: dict[str, list[str]] = {}

    for action in parser._subparsers._actions:
        if isinstance(action, argparse._SubParsersAction):
            for name, sub in action.choices.items():
                if name.startswith("_"):
                    continue
                subcmds.append(name)
                flags: list[str] = []
                for a in sub._actions:
                    for opt in a.option_strings:
                        if not opt.startswith("-"):
                            continue
                        flags.append(opt)
                subcmd_flags[name] = flags

    global_flags = ["--dry-run", "-v", "--verbose", "--version", "--tree"]

    lines = [
        "# bash completion for sepac — generated by sepac completion bash",
        "_sepac_complete() {",
        '    local cur prev words cword',
        '    _init_completion || return',
        '',
        '    local subcmds="' + " ".join(subcmds) + '"',
        '    local global_flags="' + " ".join(global_flags) + '"',
        '',
        '    # Find the subcommand',
        '    local subcmd=""',
        '    local i',
        '    for ((i=1; i < cword; i++)); do',
        '        case "${words[i]}" in',
        '            -*) ;;',
        '            *)',
        '                subcmd="${words[i]}"',
        '                break',
        '                ;;',
        '        esac',
        '    done',
        '',
        '    if [[ -z "${subcmd}" ]]; then',
        '        COMPREPLY=( $(compgen -W "${subcmds} ${global_flags}" -- "${cur}") )',
        '        return 0',
        '    fi',
        '',
        '    case "${prev}" in',
        '        --env)',
        '            local envs',
        '            envs="$(sepac _complete envs 2>/dev/null)"',
        '            COMPREPLY=( $(compgen -W "${envs}" -- "${cur}") )',
        '            return 0',
        '            ;;',
        '        --approve)',
        '            local perms',
        '            perms="$(sepac _complete perms 2>/dev/null)"',
        '            COMPREPLY=( $(compgen -W "${perms}" -- "${cur}") )',
        '            return 0',
        '            ;;',
        '    esac',
        '',
        '    case "${subcmd}" in',
    ]

    for name in subcmds:
        flags = subcmd_flags.get(name, [])
        # Commands that take APP positional
        app_cmds = {"triage", "tune", "denials", "generate", "check", "load", "status"}
        if name in app_cmds:
            lines.append(f'        {name})')
            lines.append('            if [[ "${cur}" == -* ]]; then')
            lines.append(f'                COMPREPLY=( $(compgen -W "{" ".join(flags)}" -- "${{cur}}") )')
            lines.append('            else')
            lines.append('                local apps')
            lines.append('                apps="$(sepac _complete apps 2>/dev/null)"')
            lines.append('                COMPREPLY=( $(compgen -W "${apps}" -- "${cur}") )')
            lines.append('            fi')
            lines.append('            ;;')
        else:
            lines.append(f'        {name})')
            lines.append(f'            COMPREPLY=( $(compgen -W "{" ".join(flags)}" -- "${{cur}}") )')
            lines.append('            ;;')

    lines += [
        '    esac',
        '}',
        'complete -F _sepac_complete sepac',
    ]

    print("\n".join(lines))
    return 0


def cmd_complete(args: argparse.Namespace) -> int:
    """Dynamic completion helper: sepac _complete apps|envs|perms."""
    what = args.what

    if what == "apps":
        apps: set[str] = set()
        if POLICY_TREE is not None:
            config_dir = POLICY_TREE / "config"
            if config_dir.is_dir():
                for f in config_dir.glob("*.manifest.yml"):
                    apps.add(f.name.replace(".manifest.yml", ""))
        etc_apps = Path("/etc/selinux-pac/apps")
        if etc_apps.is_dir():
            for f in etc_apps.glob("*.manifest.yml"):
                apps.add(f.name.replace(".manifest.yml", ""))
        print("\n".join(sorted(apps)))
        return 0

    if what == "envs":
        envs: set[str] = set()
        if POLICY_TREE is not None:
            ansible_dir = POLICY_TREE / "ansible"
            if ansible_dir.is_dir():
                for f in ansible_dir.glob("inventory.*.yml"):
                    name = f.name.replace("inventory.", "").replace(".yml", "")
                    if not name.endswith(".example"):
                        envs.add(name)
        print("\n".join(sorted(envs)))
        return 0

    if what == "perms":
        from policy_rules import NEEDS_REVIEW_RATIONALE
        perms = sorted({perm for _, perm in NEEDS_REVIEW_RATIONALE})
        print("\n".join(perms))
        return 0

    return 1


# ── Man page ─────────────────────────────────────────────────────────────────

def cmd_man(args: argparse.Namespace) -> int:
    """Generate groff -man source for sepac(8)."""
    import datetime

    parser = build_parser()
    date_str = datetime.date.today().strftime("%B %Y")

    lines: list[str] = []

    def _w(s: str = "") -> None:
        lines.append(s)

    _w(f'.TH SEPAC 8 "{date_str}" "selinux-pac" "System Administration"')
    _w(".SH NAME")
    _w("sepac \\- SELinux Policy as Code admin CLI")
    _w(".SH SYNOPSIS")
    _w(".B sepac")
    _w("[\\fB\\-\\-version\\fR]")
    _w("[\\fB\\-\\-tree\\fR \\fIDIR\\fR]")
    _w("[\\fB\\-\\-dry\\-run\\fR]")
    _w("[\\fB\\-v\\fR]")
    _w("\\fICOMMAND\\fR [\\fIargs\\fR]")

    _w(".SH DESCRIPTION")
    _w("Single admin CLI for SELinux policy triage, generation, CI checks,")
    _w("canary/soak/enforce lifecycle, and rollback on RHEL 9.")

    _w(".SH COMMANDS")
    _w(".SS On the QA host")

    qa_cmds = ["doctor", "triage", "tune", "denials", "generate", "check", "load", "status"]
    ansible_cmds = ["build", "publish", "canary", "soak", "enforce", "rollback"]

    # Collect help text from the subparser action
    _subcmd_help: dict[str, str] = {}
    for action in parser._subparsers._actions:
        if isinstance(action, argparse._SubParsersAction):
            for name, sub in action.choices.items():
                # help is stored on the pseudo-action for this choice
                _subcmd_help[name] = action._choices_actions[
                    [a.dest for a in action._choices_actions].index(name)
                ].help if name in [a.dest for a in action._choices_actions] else ""

    for action in parser._subparsers._actions:
        if not isinstance(action, argparse._SubParsersAction):
            continue
        for name, sub in action.choices.items():
            if name.startswith("_") or name == "completion":
                continue
            if name in ansible_cmds:
                continue
            _w(f".TP")
            flag_parts: list[str] = []
            for a in sub._actions:
                if a.option_strings:
                    for opt in a.option_strings:
                        if opt in ("--dry-run", "-v", "--verbose", "--tree", "-h", "--help"):
                            continue
                        flag_parts.append(f"\\fB{opt}\\fR")
                elif hasattr(a, "metavar") and a.metavar:
                    flag_parts.append(f"\\fI{a.metavar}\\fR")
            _w(f".B {name}")
            if flag_parts:
                _w(" ".join(flag_parts))
            _w(_subcmd_help.get(name, ""))

    _w(".SS Where Ansible runs")
    for action in parser._subparsers._actions:
        if not isinstance(action, argparse._SubParsersAction):
            continue
        for name, sub in action.choices.items():
            if name not in ansible_cmds:
                continue
            _w(f".TP")
            flag_parts = []
            for a in sub._actions:
                if a.option_strings:
                    for opt in a.option_strings:
                        if opt in ("--dry-run", "-v", "--verbose", "--tree", "-h", "--help"):
                            continue
                        flag_parts.append(f"\\fB{opt}\\fR")
                elif hasattr(a, "metavar") and a.metavar:
                    flag_parts.append(f"\\fI{a.metavar}\\fR")
            _w(f".B {name}")
            if flag_parts:
                _w(" ".join(flag_parts))
            _w(_subcmd_help.get(name, ""))

    _w(".SH FILES")
    _w(".TP")
    _w(".I /etc/selinux-pac/role")
    _w("Host role (qa, dev, staging, production). Controls which commands are allowed.")
    _w(".TP")
    _w(".I /etc/selinux-pac/apps/")
    _w("Per-app manifest copies installed by the Ansible role.")
    _w(".TP")
    _w(".I /etc/selinux-pac/sepac.conf")
    _w("Configuration file. Set \\fBtree\\fR to point at a policy tree.")

    _w(".SH EXAMPLES")
    _w("The standard 301 flow on a QA host:")
    _w(".PP")
    _w(".nf")
    _w("sepac triage shopapi")
    _w("sepac denials shopapi --since boot")
    _w("sepac generate shopapi --apply")
    _w("sepac generate shopapi --approve execmem --apply")
    _w("sepac load shopapi")
    _w("sepac status shopapi")
    _w(".fi")

    _w(".SH SEE ALSO")
    _w(".BR semanage (8),")
    _w(".BR restorecon (8),")
    _w(".BR semodule (8),")
    _w(".BR ausearch (8),")
    _w(".BR audit2why (1)")

    print("\n".join(lines))
    return 0

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="sepac",
        description="SELinux Policy as Code — admin CLI",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "On the QA host:\n"
            "  doctor     Check host prerequisites\n"
            "  triage     Does Red Hat already ship policy?\n"
            "  tune       Vendor-domain tune report\n"
            "  denials    Show AVC denials for an app\n"
            "  generate   Generate policy from audit log\n"
            "  check      CI gate: manifest + compile + semantics\n"
            "  load       Load module on QA (semodule + restorecon + ports)\n"
            "  status     Six-line status for an app\n"
            "\n"
            "Where Ansible runs:\n"
            "  build      Build RPMs\n"
            "  publish    Publish RPMs to internal repo\n"
            "  canary     Deploy canary via Ansible\n"
            "  soak       Soak monitor or status\n"
            "  enforce    Enforce after soak\n"
            "  rollback   Emergency rollback via Ansible\n"
        ),
    )
    parser.add_argument("--version", action="store_true", help="Print version and exit")
    parser.add_argument("--tree", default=None, metavar="DIR",
                        help="Policy tree root (config/, selinux/, ansible/)")
    parser.add_argument("--dry-run", action="store_true", help="Print commands, run nothing")
    parser.add_argument("-v", "--verbose", action="store_true", help="Print each command before running")

    subs = parser.add_subparsers(dest="command", metavar="COMMAND")

    def _common(p: argparse.ArgumentParser) -> None:
        """Add --dry-run, -v, and --tree to a subparser so they work after the subcommand too."""
        p.add_argument("--dry-run", action="store_true", default=False, help=argparse.SUPPRESS)
        p.add_argument("-v", "--verbose", action="store_true", default=False, help=argparse.SUPPRESS)
        p.add_argument("--tree", default=argparse.SUPPRESS, help=argparse.SUPPRESS)

    # ── On the QA host ────────────────────────────────────────────────────

    p = subs.add_parser("doctor", help="Check host prerequisites")
    _common(p)
    p.set_defaults(func=cmd_doctor)

    p = subs.add_parser("triage", help="Does Red Hat already ship policy?")
    p.add_argument("app", metavar="APP")
    p.add_argument("--unit", default=None, help="systemd unit (default: APP.service)")
    p.add_argument("--manifest", default=None, metavar="PATH", help="Manifest file path")
    _common(p)
    p.set_defaults(func=cmd_triage)

    p = subs.add_parser("tune", help="Vendor-domain tune report")
    p.add_argument("app", metavar="APP")
    p.add_argument("--unit", default=None, help="systemd unit")
    p.add_argument("--manifest", default=None, metavar="PATH", help="Manifest file path")
    _common(p)
    p.set_defaults(func=cmd_tune)

    p = subs.add_parser("denials", help="Show AVC denials for an app")
    p.add_argument("app", metavar="APP")
    p.add_argument("--since", default="recent", help="ausearch -ts value (default: recent)")
    p.add_argument("--enforced", action="store_true", help="Only permissive=0 lines")
    p.add_argument("--why", action="store_true", help="Pipe kept lines to audit2why")
    p.add_argument("--last", type=int, default=10, help="Show last N lines (default: 10)")
    p.add_argument("--manifest", default=None, metavar="PATH", help="Manifest file path")
    _common(p)
    p.set_defaults(func=cmd_denials)

    p = subs.add_parser("generate", help="Generate policy from audit log")
    p.add_argument("app", metavar="APP")
    p.add_argument("--approve", action="append", metavar="PERM",
                   help="Approve a needs_review permission (repeatable)")
    p.add_argument("--apply", action="store_true", help="Copy to selinux/")
    p.add_argument("--force", metavar="REASON", help="Bypass vendor check")
    p.add_argument("--skip-export", action="store_true", help="Use existing policy_out/avc.log")
    p.add_argument("--manifest", default=None, metavar="PATH", help="Manifest file path")
    _common(p)
    p.set_defaults(func=cmd_generate)

    p = subs.add_parser("check", help="CI gate: manifest + compile + semantics")
    p.add_argument("app", metavar="APP")
    p.add_argument("--manifest", default=None, metavar="PATH", help="Manifest file path")
    _common(p)
    p.set_defaults(func=cmd_check)

    p = subs.add_parser("load", help="Load module on QA (semodule + restorecon + ports)")
    p.add_argument("app", metavar="APP")
    p.add_argument("--enforce", action="store_true", default=False,
                   help="Remove permissive exception after loading (semanage permissive -d)")
    p.add_argument("--manifest", default=None, metavar="PATH", help="Manifest file path")
    _common(p)
    p.set_defaults(func=cmd_load)

    p = subs.add_parser("status", help="Six-line status for an app")
    p.add_argument("app", metavar="APP")
    p.add_argument("--manifest", default=None, metavar="PATH", help="Manifest file path")
    _common(p)
    p.set_defaults(func=cmd_status)

    # ── Where Ansible runs ────────────────────────────────────────────────

    p = subs.add_parser("canary", help="Deploy canary via Ansible")
    p.add_argument("--env", required=True, help="dev, staging, or production")
    p.add_argument("--limit", default=None, help="Ansible --limit")
    _common(p)
    p.set_defaults(func=cmd_canary)

    p = subs.add_parser("soak", help="Soak monitor or status")
    p.add_argument("--env", required=True, help="dev, staging, or production")
    p.add_argument("--limit", default=None, help="Ansible --limit")
    p.add_argument("--status", action="store_true", help="Read-only soak_status.yml")
    _common(p)
    p.set_defaults(func=cmd_soak)

    p = subs.add_parser("enforce", help="Enforce after soak")
    p.add_argument("--env", required=True, help="dev, staging, or production")
    p.add_argument("--ticket", required=True, help="Change ticket (required)")
    p.add_argument("--limit", default=None, help="Ansible --limit")
    p.add_argument("--skip-soak-days", action="store_true", help="Skip day count gate")
    p.add_argument("--break-glass", metavar="REASON", help="Force enforce with reason")
    _common(p)
    p.set_defaults(func=cmd_enforce)

    p = subs.add_parser("rollback", help="Emergency rollback via Ansible")
    p.add_argument("--env", required=True, help="dev, staging, or production")
    p.add_argument("--limit", default=None, help="Ansible --limit")
    _common(p)
    p.set_defaults(func=cmd_rollback)

    p = subs.add_parser("build", help="Build RPMs")
    p.add_argument("--allow-dirty", action="store_true", help="Skip dirty-tree check")
    _common(p)
    p.set_defaults(func=cmd_build)

    p = subs.add_parser("publish", help="Publish RPMs to internal repo")
    p.add_argument("--env-file", default="dist/lab-signing.env",
                   help="Signing env file (default: dist/lab-signing.env)")
    _common(p)
    p.set_defaults(func=cmd_publish)

    # ── Utility commands ──────────────────────────────────────────────────

    p = subs.add_parser("completion", help="Print shell completion script")
    p.add_argument("shell", choices=["bash"], help="Shell (only bash supported)")
    p.set_defaults(func=cmd_completion)

    p = subs.add_parser("_complete", help=argparse.SUPPRESS)
    p.add_argument("what", choices=["apps", "envs", "perms"])
    p.add_argument("--tree", default=argparse.SUPPRESS, help=argparse.SUPPRESS)
    p.set_defaults(func=cmd_complete)

    p = subs.add_parser("_man", help=argparse.SUPPRESS)
    p.set_defaults(func=cmd_man)

    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if getattr(args, "version", False):
        print(f"sepac {_sepac_version()}")
        return 0
    if not args.command:
        parser.print_help()
        return 2
    _init_trees(args)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
