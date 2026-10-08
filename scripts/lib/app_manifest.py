#!/usr/bin/env python3
"""Load and validate per-app manifest YAML for deploy/readiness scripts."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover - CI installs pyyaml
    yaml = None  # type: ignore


REQUIRED_TOP = ("app_name", "domain")
REQUIRED_PATHS = ("install_root", "var_dir")


def _deep_get(data: dict[str, Any], *keys: str, default: Any = None) -> Any:
    cur: Any = data
    for key in keys:
        if not isinstance(cur, dict) or key not in cur:
            return default
        cur = cur[key]
    return cur


def default_manifest_path(project_root: Path, app_name: str) -> Path:
    return project_root / "config" / f"{app_name}.manifest.yml"


def resolve_manifest_path(
    explicit: str | None = None,
    *,
    project_root: Path | None = None,
    app_name: str | None = None,
) -> Path | None:
    if explicit:
        path = Path(explicit)
        return path if path.is_file() else None
    env_path = __import__("os").environ.get("APP_MANIFEST")
    if env_path:
        path = Path(env_path)
        return path if path.is_file() else None
    root = project_root or Path(__file__).resolve().parents[2]
    name = app_name or __import__("os").environ.get("POLICY_APP", "myapp")
    candidate = default_manifest_path(root, name)
    return candidate if candidate.is_file() else None


def load_raw(path: Path) -> dict[str, Any]:
    if yaml is None:
        raise RuntimeError("PyYAML required: pip install pyyaml")
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"{path}: manifest root must be a mapping")
    return data


def normalize(raw: dict[str, Any]) -> dict[str, Any]:
    app_name = str(raw["app_name"]).strip()
    domain = str(raw["domain"]).strip()
    paths_in = raw.get("paths") or {}
    if not isinstance(paths_in, dict):
        raise ValueError("paths must be a mapping")

    install_root = paths_in.get("install_root", f"/opt/{app_name}")
    var_dir = paths_in.get("var_dir", f"/var/lib/{app_name}")
    log_dir = paths_in.get("log_dir", f"/var/log/{app_name}")
    runtime_dir = paths_in.get("runtime_dir", f"/run/{app_name}")
    var_opt_dir = paths_in.get("var_opt_dir")
    extras_in = paths_in.get("extra_fc_roots") or []
    if isinstance(extras_in, str):
        extras_in = [extras_in]
    extra_fc_roots = [str(x) for x in extras_in if x]

    services_in = raw.get("services") or {}
    if not isinstance(services_in, dict):
        raise ValueError("services must be a mapping")
    primary = services_in.get("primary") or {}
    if not isinstance(primary, dict):
        raise ValueError("services.primary must be a mapping")
    primary_unit = primary.get("unit", f"{app_name}.service")
    primary_domain = primary.get("domain", domain)

    backend_block = services_in.get("backend")
    backend: dict[str, Any] | None = None
    if backend_block:
        if not isinstance(backend_block, dict):
            raise ValueError("services.backend must be a mapping")
        backend = {
            "unit": backend_block.get("unit", f"{app_name}-backend.service"),
            "domain": backend_block.get("domain", f"{app_name}_backend_t"),
        }

    http_in = raw.get("http") or {}
    if not isinstance(http_in, dict):
        raise ValueError("http must be a mapping")
    http_host = http_in.get("host", "127.0.0.1")
    http_port = int(http_in.get("port", 8080))
    endpoints_raw = http_in.get("endpoints") or ["/"]
    if not isinstance(endpoints_raw, list) or not endpoints_raw:
        raise ValueError("http.endpoints must be a non-empty list")
    endpoints = [str(p if isinstance(p, str) else p.get("path")) for p in endpoints_raw]

    backend_http: dict[str, Any] | None = None
    if backend and http_in.get("backend"):
        bh = http_in["backend"]
        if not isinstance(bh, dict):
            raise ValueError("http.backend must be a mapping")
        backend_http = {
            "port": int(bh.get("port", 8081)),
            "health_path": str(bh.get("health_path", "/health")),
        }
    elif backend:
        backend_http = {"port": 8081, "health_path": "/health"}

    deploy_in = raw.get("deploy") or {}
    ops_dir = f"/var/lib/selinux-policy-ops/{app_name}"
    soak_marker = deploy_in.get("soak_marker_file", f"{ops_dir}/selinux_canary_deployed_at")
    deploy_report = deploy_in.get("deploy_report_file", f"{ops_dir}/selinux_deploy_report.json")

    policy_in = raw.get("policy") or {}
    module_dir = policy_in.get("module_dir", "selinux")

    return {
        "app_name": app_name,
        "domain": domain,
        "paths": {
            "install_root": str(install_root),
            "var_dir": str(var_dir),
            "log_dir": str(log_dir),
            "runtime_dir": str(runtime_dir),
            **({"var_opt_dir": str(var_opt_dir)} if var_opt_dir else {}),
            **({"extra_fc_roots": extra_fc_roots} if extra_fc_roots else {}),
        },
        "services": {
            "primary": {"unit": str(primary_unit), "domain": str(primary_domain)},
            "backend": backend,
        },
        "http": {
            "host": str(http_host),
            "port": http_port,
            "endpoints": endpoints,
            "backend": backend_http,
        },
        "selinux_ports": raw.get("selinux_ports") or [],
        "integration_tests": raw.get("integration_tests"),
        "policy": {"module_dir": str(module_dir), "service_name": str(primary_unit)},
        "deploy": {
            "soak_marker_file": str(soak_marker),
            "deploy_report_file": str(deploy_report),
        },
    }


def validate_normalized(manifest: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    for key in REQUIRED_TOP:
        if not manifest.get(key):
            errors.append(f"missing required field: {key}")
    for key in REQUIRED_PATHS:
        if not manifest["paths"].get(key):
            errors.append(f"missing paths.{key}")
    if not manifest["services"]["primary"].get("unit"):
        errors.append("missing services.primary.unit")
    if not manifest["http"]["endpoints"]:
        errors.append("http.endpoints must not be empty")
    backend = manifest["services"].get("backend")
    if backend and not manifest["http"].get("backend"):
        errors.append("services.backend defined but http.backend missing")
    return errors


def load_manifest(path: Path) -> dict[str, Any]:
    raw = load_raw(path)
    manifest = normalize(raw)
    errors = validate_normalized(manifest)
    if errors:
        raise ValueError(f"{path}: " + "; ".join(errors))
    return manifest


def policy_source_paths(project_root: Path, manifest: dict[str, Any]) -> dict[str, Path]:
    """Resolve .te / .fc / policy_version.txt from manifest policy.module_dir."""
    app_name = manifest["app_name"]
    rel = manifest["policy"]["module_dir"]
    mod_dir = Path(rel)
    if not mod_dir.is_absolute():
        mod_dir = (project_root / mod_dir).resolve()
    te = mod_dir / f"{app_name}.te"
    fc = mod_dir / f"{app_name}.fc"
    version_file = mod_dir / "policy_version.txt"
    if not version_file.is_file():
        legacy = (project_root / "selinux" / "policy_version.txt").resolve()
        if legacy.is_file():
            version_file = legacy
    return {
        "module_dir": mod_dir,
        "te": te,
        "fc": fc,
        "version_file": version_file,
    }


def manifest_paths_csv(manifest: dict[str, Any]) -> str:
    """Comma-separated path substrings for AVC filtering (manifest paths only)."""
    paths = manifest["paths"]
    order = ("install_root", "var_dir", "log_dir", "runtime_dir", "var_opt_dir")
    parts = [str(paths[k]) for k in order if paths.get(k)]
    extras = paths.get("extra_fc_roots") or []
    if isinstance(extras, str):
        extras = [extras]
    parts.extend(str(x) for x in extras if x)
    if not parts:
        raise ValueError("manifest paths yield no AVC path filters")
    return ",".join(parts)


def manifest_service_domains_csv(manifest: dict[str, Any]) -> str:
    """Comma-separated process domains for sesearch / blast-radius collection."""
    domains: set[str] = set()
    for _role, _unit, domain in service_units_ordered(manifest):
        domains.add(str(domain))
    top = manifest.get("domain")
    if top:
        domains.add(str(top))
    if not domains:
        raise ValueError("manifest has no service domains")
    return ",".join(sorted(domains))


def service_units_ordered(manifest: dict[str, Any]) -> list[tuple[str, str, str]]:
    """Return list of (role, unit, domain) — backend before primary when present."""
    items: list[tuple[str, str, str]] = []
    backend = manifest["services"].get("backend")
    if backend:
        items.append(("backend", backend["unit"], backend["domain"]))
    primary = manifest["services"]["primary"]
    items.append(("primary", primary["unit"], primary["domain"]))
    return items


def shell_export(manifest: dict[str, Any]) -> str:
    primary = manifest["services"]["primary"]
    backend = manifest["services"].get("backend")
    lines = [
        f"APP_NAME={json.dumps(manifest['app_name'])}",
        f"APP_DOMAIN={json.dumps(manifest['domain'])}",
        f"PRIMARY_DOMAIN={json.dumps(primary['domain'])}",
        f"PATHS_CSV={json.dumps(manifest_paths_csv(manifest))}",
        f"PRIMARY_SERVICE={json.dumps(primary['unit'])}",
        f"HTTP_HOST={json.dumps(manifest['http']['host'])}",
        f"HTTP_PORT={manifest['http']['port']}",
        f"ENDPOINT_PATHS={json.dumps(json.dumps(manifest['http']['endpoints']))}",
    ]
    if backend:
        lines.append(f"BACKEND_SERVICE={json.dumps(backend['unit'])}")
        lines.append(f"BACKEND_DOMAIN={json.dumps(backend['domain'])}")
        bh = manifest["http"].get("backend") or {}
        lines.append(f"BACKEND_HTTP_PORT={bh.get('port', 8081)}")
        lines.append(f"BACKEND_HEALTH_PATH={json.dumps(bh.get('health_path', '/health'))}")
        lines.append("HAS_BACKEND=1")
    else:
        lines.append("BACKEND_DOMAIN=")
        lines.append("HAS_BACKEND=0")
    return "\n".join(lines)


def domain_context_matches(endpoint_data: dict[str, Any], manifest: dict[str, Any]) -> bool:
    ctx = endpoint_data.get("domain_context") or {}
    for _role, unit, domain in service_units_ordered(manifest):
        if ctx.get(unit) != domain:
            return False
    return True


def service_roles(manifest: dict[str, Any]) -> list[tuple[str, str]]:
    """Return (role_name, unit) for deploy report service status."""
    items: list[tuple[str, str]] = []
    backend = manifest["services"].get("backend")
    if backend:
        items.append(("backend", backend["unit"]))
    primary = manifest["services"]["primary"]
    items.append(("primary", primary["unit"]))
    return items


def main() -> int:
    parser = argparse.ArgumentParser(description="App manifest loader")
    parser.add_argument("command", choices=("json", "validate", "shell-export", "resolve", "check-domain-context", "paths-csv", "domains-csv"))
    parser.add_argument("path", nargs="?", help="Manifest YAML path or endpoint JSON for check-domain-context")
    parser.add_argument("endpoint_json", nargs="?", help="Endpoint JSON path for check-domain-context")
    parser.add_argument("--app-name", default=None)
    args = parser.parse_args()

    if args.command == "resolve":
        path = resolve_manifest_path(args.path, app_name=args.app_name)
        if path:
            print(path)
            return 0
        return 1

    if args.command == "check-domain-context":
        if not args.path or not args.endpoint_json:
            print("usage: check-domain-context MANIFEST ENDPOINT_JSON", file=sys.stderr)
            return 1
        manifest = load_manifest(Path(args.path))
        endpoint_data = json.loads(Path(args.endpoint_json).read_text(encoding="utf-8"))
        print("yes" if domain_context_matches(endpoint_data, manifest) else "no")
        return 0 if domain_context_matches(endpoint_data, manifest) else 1

    if not args.path:
        path = resolve_manifest_path(app_name=args.app_name)
        if not path:
            print("No manifest found", file=sys.stderr)
            return 1
    else:
        path = Path(args.path)

    if args.command == "validate":
        try:
            load_manifest(path)
        except (ValueError, OSError, RuntimeError) as exc:
            print(str(exc), file=sys.stderr)
            return 1
        print(f"OK {path}")
        return 0

    manifest = load_manifest(path)
    if args.command == "json":
        print(json.dumps(manifest, indent=2))
        return 0
    if args.command == "shell-export":
        print(shell_export(manifest))
        return 0
    if args.command == "paths-csv":
        print(manifest_paths_csv(manifest))
        return 0
    if args.command == "domains-csv":
        print(manifest_service_domains_csv(manifest))
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
