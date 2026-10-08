"""
avc_preprocess.py — Merge, dedupe, and subtract existing allows from AVC evidence
before sending structured access needs to the LLM.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from selinux_gen import AvcEntry

# Braced `{ read write }` and a single permission without braces (`execmem`).
ALLOW_RULE_RE = re.compile(
    r"^\s*allow\s+(\S+)\s+(\S+):(\S+)\s+(?:\{([^}]+)\}|([^{}\s;]+))\s*;\s*$",
    re.MULTILINE,
)


@dataclass(frozen=True)
class AccessNeed:
    src_type: str
    tgt_type: str
    tclass: str
    perms: frozenset[str]

    @property
    def key(self) -> tuple[str, str, str]:
        return (self.src_type, self.tgt_type, self.tclass)


def extract_type(context: str) -> str:
    """Extract SELinux type from a context string (user:role:type:level)."""
    if not context:
        return ""
    parts = context.split(":")
    if len(parts) >= 3:
        return parts[2]
    return context


def normalize_perms(perm_str: str) -> frozenset[str]:
    """Parse permission tokens from AVC denied { ... } or perm= fields."""
    cleaned = perm_str.strip().strip("{}").strip()
    if not cleaned:
        return frozenset()
    return frozenset(token for token in cleaned.split() if token)


def merge_avc_entries(entries: list[AvcEntry]) -> list[AccessNeed]:
    """Group AVC lines by (src_type, tgt_type, class) and union permissions."""
    merged: dict[tuple[str, str, str], set[str]] = {}
    for entry in entries:
        src_type = extract_type(entry.scontext)
        tgt_type = extract_type(entry.tcontext)
        if not src_type or not tgt_type or not entry.tclass:
            continue
        key = (src_type, tgt_type, entry.tclass)
        merged.setdefault(key, set()).update(normalize_perms(entry.perm))

    needs: list[AccessNeed] = []
    for (src_type, tgt_type, tclass), perms in sorted(merged.items()):
        if perms:
            needs.append(AccessNeed(src_type, tgt_type, tclass, frozenset(perms)))
    return needs


def parse_existing_allows(te_text: str) -> dict[tuple[str, str, str], frozenset[str]]:
    """Parse allow rules from existing .te source into a lookup table.

    `self` is the source domain, so an AVC whose target type is that domain
    matches `allow domain self:class perm`.
    """
    allows: dict[tuple[str, str, str], set[str]] = {}

    def add(src_type: str, tgt_type: str, tclass: str, perms: frozenset[str]) -> None:
        allows.setdefault((src_type, tgt_type, tclass), set()).update(perms)

    for match in ALLOW_RULE_RE.finditer(te_text):
        src_type, tgt_type, tclass, braced, single = match.groups()
        perms = normalize_perms(braced if braced is not None else single or "")
        if not perms:
            continue
        add(src_type, tgt_type, tclass, perms)
        if tgt_type == "self":
            add(src_type, src_type, tclass, perms)
    return {key: frozenset(perms) for key, perms in allows.items()}


def subtract_covered(
    merged: list[AccessNeed],
    existing: dict[tuple[str, str, str], frozenset[str]],
) -> tuple[list[AccessNeed], list[AccessNeed]]:
    """Split merged AVC needs into net-new vs already covered by existing .te."""
    net_new: list[AccessNeed] = []
    already_covered: list[AccessNeed] = []

    for need in merged:
        existing_perms = existing.get(need.key, frozenset())
        uncovered = need.perms - existing_perms
        covered = need.perms & existing_perms

        if uncovered:
            net_new.append(
                AccessNeed(need.src_type, need.tgt_type, need.tclass, frozenset(uncovered))
            )
        if covered:
            already_covered.append(
                AccessNeed(need.src_type, need.tgt_type, need.tclass, frozenset(covered))
            )

    return net_new, already_covered


def _format_perm_list(perms: frozenset[str]) -> str:
    return ", ".join(sorted(perms))


def _format_need_table(needs: list[AccessNeed]) -> str:
    if not needs:
        return "(none)"
    lines = ["| Source | Target | Class | Permissions |", "| --- | --- | --- | --- |"]
    for need in needs:
        lines.append(
            f"| {need.src_type} | {need.tgt_type} | {need.tclass} | {_format_perm_list(need.perms)} |"
        )
    return "\n".join(lines)


MACRO_COVERAGE_NOTE = (
    "Note: subtraction parses explicit allow lines only; rules expanded by "
    "init_daemon_domain, domain_auto_trans, and files_type macros may already cover some AVCs."
)


def format_structured_summary(
    net_new: list[AccessNeed],
    already_covered: list[AccessNeed],
    stats: dict[str, int],
) -> str:
    """Build human- and LLM-friendly summary text."""
    sections = [
        MACRO_COVERAGE_NOTE,
        "",
        "## Net-new access needs (from AVCs, not in existing .te)",
        _format_need_table(net_new),
        "",
        "## Already covered by existing policy (for reference only)",
        _format_need_table(already_covered),
        "",
        (
            "Stats: "
            f"raw={stats['raw']} merged={stats['merged']} "
            f"net_new={stats['net_new']} already_covered={stats['already_covered']}"
        ),
    ]
    return "\n".join(sections)


def preprocess_avc_entries(
    entries: list[AvcEntry],
    *,
    existing_te: str = "",
) -> tuple[str, dict[str, int]]:
    """
    Merge AVC entries, subtract existing allows, return summary text and stats.

    When every permission is already covered, net-new is empty; callers should
    fall back to the merged set for LLM input.
    """
    raw_count = len(entries)
    merged = merge_avc_entries(entries)
    existing = parse_existing_allows(existing_te)
    net_new, already_covered = subtract_covered(merged, existing)

    stats = {
        "raw": raw_count,
        "merged": len(merged),
        "net_new": len(net_new),
        "already_covered": len(already_covered),
    }

    summary = format_structured_summary(net_new, already_covered, stats)
    return summary, stats


def preprocess_avc_file(
    path: Path,
    domain: str,
    *,
    existing_te: str = "",
) -> tuple[str, dict[str, int]]:
    """Load AVC file, filter, merge, subtract, and return structured summary."""
    from selinux_gen import filter_avc_entries, filter_prompt_avc_entries, parse_avc_line

    if not path.is_file():
        raise RuntimeError(f"Audit log not found: {path}")

    entries: list[AvcEntry] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "type=AVC" in line:
            entries.append(parse_avc_line(line))

    entries = filter_avc_entries(entries, domain)
    entries = filter_prompt_avc_entries(entries, domain)
    return build_llm_avc_summary(entries, existing_te=existing_te)


def preprocess_avc_lines(
    lines: list[str],
    domain: str,
    *,
    existing_te: str = "",
) -> tuple[str, dict[str, int]]:
    """Parse raw AVC lines (e.g. from ausearch), filter, merge, subtract."""
    from selinux_gen import filter_avc_entries, filter_prompt_avc_entries, parse_avc_line

    entries: list[AvcEntry] = []
    for line in lines:
        if "type=AVC" in line:
            entries.append(parse_avc_line(line))

    entries = filter_avc_entries(entries, domain)
    entries = filter_prompt_avc_entries(entries, domain)
    return build_llm_avc_summary(entries, existing_te=existing_te)


def build_llm_avc_summary(
    entries: list[AvcEntry],
    *,
    existing_te: str = "",
) -> tuple[str, dict[str, int]]:
    """
    Build the structured summary for LLM input.

    When subtracting existing .te leaves no net-new rows, return a no-changes
    summary instead of re-sending the full merged table to the LLM.
    """
    summary, stats = preprocess_avc_entries(entries, existing_te=existing_te)
    if stats["net_new"] == 0 and stats["merged"] > 0:
        merged = merge_avc_entries(entries)
        existing = parse_existing_allows(existing_te)
        _, already_covered = subtract_covered(merged, existing)
        stats = dict(stats)
        stats["no_changes_needed"] = 1
        summary = "\n".join(
            [
                MACRO_COVERAGE_NOTE,
                "",
                "## Net-new access needs (from AVCs, not in existing .te)",
                "(none — all merged AVC permissions appear covered by existing policy)",
                "",
                "## Already covered by existing policy (for reference only)",
                _format_need_table(already_covered),
                "",
                (
                    "Stats: "
                    f"raw={stats['raw']} merged={stats['merged']} "
                    f"net_new=0 already_covered={stats['already_covered']} "
                    "no_changes_needed=1"
                ),
                "",
                "No te_content changes required unless new AVCs appear after redeploy.",
            ]
        )
    return summary, stats
