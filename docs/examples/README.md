# Sample outputs

Static copies of CLI output for reviews when you cannot run staging or `assemble_pr_body.sh` live.

**Where to regenerate live output:** SELinux **Linux host** (rhel-qa) at **repo root**. Offline-only: use [`fixtures/offline/`](fixtures/offline/).

| File | Live equivalent | Use in demo |
|------|-----------------|-------------|
| [`pr_summary.example.md`](pr_summary.example.md) | `policy_out/pr_summary.md` | Part 4 — plain-English admin summary |
| [`pr_body.example.md`](pr_body.example.md) | `policy_out/pr_body.md` | Part 4 — GitHub PR body + checklist |

Live policy in `selinux/` is **v1.1.3**. [`pr_body.example.md`](pr_body.example.md) / [`pr_summary.example.md`](pr_summary.example.md) are **frozen samples** (v1.1.2). `fixtures/offline/generated/` is kept in sync with `selinux/` via `refresh_offline_fixture.sh`. Regenerate live `policy_out/` on a SELinux host with:

| | |
|--|--|
| **Where** | **Repo root** on rhel-qa (`sudo` staging) |
| **Why** | Refreshes `policy_out/pr_summary.md` and `pr_body.md` to match current `selinux/` |

```bash
sudo bash scripts/dev_generate_policy.sh --apply
bash scripts/assemble_pr_body.sh
# → policy_out/pr_summary.md and policy_out/pr_body.md
```

Deterministic verdict fixtures: [`fixtures/deterministic/`](fixtures/deterministic/). Compile on rhel-qa with `selinux-policy-devel`.

Do not edit `policy_out/` in Git — `.te`, `.fc`, and `policy_version.txt` there are local build output (gitignored). Offline demos use [`fixtures/offline/`](fixtures/offline/); refresh with `bash scripts/refresh_offline_fixture.sh` when `selinux/` bumps.
