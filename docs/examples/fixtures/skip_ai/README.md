# Offline fixtures (`--skip-ai`)

Used by `scripts/lib/stage_skip_ai_fixture.sh` for offline generation without an API key. Prefer the default **deterministic** engine ([`201 — Generate a module`](../../../developers/201-CODE_WALKTHROUGH.md#generate-a-module)).

| Path | Role |
|------|------|
| `baseline/` | Older module snapshot (**1.1.0**) — shown as “before” in Act 3 diff |
| `generated/` | Expected AI output — must match `selinux/myapp.{te,fc}` for deploy/enforce |
| `avc.log` | Recorded audit lines fed to Act 4 PR assembly |

Refresh `generated/` after bumping `selinux/`:

```bash
bash scripts/refresh_skip_ai_fixture.sh
```
