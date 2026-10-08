# 201 — Code walkthrough

This guide answers: **“What files are in this project, and how do they work together?”**

You do **not** need to know every script on day one. Read this in order, pause when something is new, and use the linked docs for deeper topics.

| Your goal | Start here |
|-----------|------------|
| Understand SELinux words (domain, AVC, `.te`) | **[102](../training/102-SELINUX_BASICS.md)** §1–7 |
| **Practice commands on a SELinux host** | **[101](../training/101-SELINUX.md)**, then the talk in **[202](202-DEMO_GUIDE.md)** |
| See how this tool fits together | [What SELinux PaC does](#what-selinux-pac-does-in-plain-english) → [Story of one policy change](#story-of-one-policy-change) |
| Find a folder or file | [Directory map](#directory-map-what-each-folder-is-for) |
| Three-app customer talk | **[202](202-DEMO_GUIDE.md)** — finish **101** first |
| Deploy to real servers | **[203](203-RHEL_TWO_HOST.md)** then **[301](../admin/301-ANSIBLE_OPERATIONS.md)** |

**Time:** about 30–45 minutes if you read the basics doc first; 60+ minutes if you read both cover to cover.

**Doc map:** [docs/README.md](../README.md) — reading order for all guides.

---

## Where to run commands (read this once)

| Environment | When to use it | Typical commands from this guide |
|-------------|----------------|----------------------------------|
| **Repo root on any OS** | Offline tests, Python CLI, reading git | `make check`, `python3 cli/deterministic_gen.py --explain …` |
| **RHEL two-host lab** | Default: QA + prod boxes | `bash scripts/setup_rhel_hosts.sh write …` — [203-RHEL_TWO_HOST.md](203-RHEL_TWO_HOST.md) |
| **Native Linux with SELinux** (RHEL **QA**) | Staging, demo, soak, `semanage` | `sudo bash scripts/demo_bootstrap.sh --shopapi-only`, `curl 127.0.0.1:8091/health` |
| **RHEL prod** | Ansible deploy lifecycle | Playbooks with `-i ansible/inventory.production.yml` |

macOS has no SELinux — [203-RHEL_TWO_HOST.md](203-RHEL_TWO_HOST.md) then SSH to **rhel-qa**.

**Repo root** = directory containing `scripts/` and `docs/` (after `git clone`).

---

## Words you will see in this repo

If any term is fuzzy, open [102-SELINUX_BASICS.md](../training/102-SELINUX_BASICS.md). Quick reminders:

| Term | Plain English |
|------|----------------|
| **Policy** | Rules that say which labeled process may touch which labeled files, ports, etc. |
| **`.te` file** | Text file with **allow** rules and types (Type Enforcement). |
| **`.fc` file** | Maps paths like `/var/lib/myapp` to file **types** so `restorecon` labels disks correctly. |
| **`.pp` file** | Compiled policy **module** you install with `semodule -i`. |
| **AVC** | A log line: “this process tried to do X and policy said no.” |
| **Domain** | The SELinux type of a **running** process (e.g. `myapp_t`). |
| **Manifest** | YAML file listing app name, paths, HTTP test URLs, and domains — so scripts do not hardcode `myapp`. |
| **semanage** | Linux admin tool that changes SELinux’s **live** settings (per-domain permissive, port labels, booleans) — see [102-SELINUX_BASICS.md §7](../training/102-SELINUX_BASICS.md) |
| **`policy_out/`** | Local scratch folder for generated files (not committed to git). |
| **`selinux/`** | The **real** policy source your team reviews in pull requests. |

---

## What SELinux PaC does in plain English

**SELinux PaC** is the admin + developer tool that ships SELinux policy the same way you ship the application:

1. A **reference app** runs on a Linux host with SELinux on. The customer talk uses Tomcat App A/B plus Spring Boot `demo/shopapi/` (swap in your service). Offline `make check` classifies golden AVCs against `selinux/myapp.te` — it does not start an app.
2. While the app domain is **permissive**, the kernel **logs** denials (AVCs) instead of blocking everything.
3. Scripts **collect** those logs and **generate** updates to `.te` / `.fc` with the deterministic engine.
4. **CI** checks forbidden patterns and version consistency (generator already ran the same forbidden-pattern script). Compile and semantics run on **rhel-qa**.
5. **Ansible Automation Platform (AAP)** deploys a new module (**Release canary**), runs **Soak monitor** (net-new vs installed policy), then **Promote to enforce**. A denial after ship is a **PR**, not a live host patch ([301-ANSIBLE_OPERATIONS.md#a-denial-after-ship](../admin/301-ANSIBLE_OPERATIONS.md#a-denial-after-ship)).

You are not expected to memorize every bash script. Most days you touch **`selinux/`**, **`config/*.manifest.yml`**, **`scripts/dev_generate_policy.sh`**, and AAP.

---

## Story of one policy change

Follow this narrative once; later sections add file names and detail.

```mermaid
flowchart TD
  A[Developer runs staging app] --> B[App hits missing allow rule]
  B --> C[AVC lines in audit log]
  C --> D[dev_generate_policy.sh exports AVCs]
  D --> E[deterministic_gen.py]
  E --> F[Files in policy_out/]
  F --> G[Human review + PR to selinux/]
  G --> H[GitHub CI: forbidden-patterns]
  H --> I[Merge]
  I --> J[Ansible canary deploy]
  J --> K[Soak: soak_monitor.yml clean first-ship]
  K --> L[Ansible enforce]
  L --> M[New URL denied]
  M --> N[emergency_rollback.yml]
  N --> O[Generate on rhel-qa + second PR]
```

**Step by step:**

1. **Staging** — `scripts/demo_bootstrap.sh --shopapi-only` installs Spring Boot and puts `shopapi_t` in permissive mode so you can collect denials safely.
2. **Trigger the app** — curl first-ship `/health` `/state` `/log` on :8091. See [102-SELINUX_BASICS.md §9](../training/102-SELINUX_BASICS.md) for the mapping.
3. **Export AVCs** — `scripts/dev_generate_policy.sh --app shopapi` calls `lib/avc_query.sh` with paths and domains from **`config/shopapi.manifest.yml`**.
4. **Generate policy** — **`cli/deterministic_gen.py`** classifies each denial and writes the `.te` / `.fc` updates. It runs offline, from rules in the repo.
5. **Review** — Output lands in **`policy_out/`** (`.te`, `.fc`, `pr_summary.md`, `findings.json`). You compare to **`selinux/`** and open a PR.
6. **CI** — Workflow **`selinux-policy-ci.yml`** runs `forbidden-patterns` and `version-consistency`. The generator already ran the same forbidden-pattern check, so these jobs should pass.
7. **Deploy** — Admins use **AAP** ([`ansible/aap/`](../../ansible/aap/)): workflow **Release canary**, daily **Soak monitor**, then **Promote to enforce**. Soak fail: [301-ANSIBLE_OPERATIONS.md#a-denial-after-ship](../admin/301-ANSIBLE_OPERATIONS.md#a-denial-after-ship). See [301-ANSIBLE_OPERATIONS.md](../admin/301-ANSIBLE_OPERATIONS.md).

**Golden rule:** committed policy lives in **`selinux/`**. **`policy_out/`** is disposable local output.

---

## Directory map — what each folder is for

Think of the repo in **layers**: app → policy source → generators → automation → deploy.

| Path | Beginner description |
|------|----------------------|
| [`demo/shopapi/`](../../demo/shopapi/) | Spring Boot **demo** JVM. Policy seed: **`selinux/shopapi/`**. |
| [`selinux/`](../../selinux/) | **`myapp.te`** (offline generator golden), **`shopapi/`** (demo generate target), **`payments/`** (CI multi-module). |
| [`config/`](../../config/) | **`shopapi.manifest.yml`** (demo), **`myapp.manifest.yml`** (generator fixture). |
| [`cli/`](../../cli/) | Python tools: read AVC logs, classify denials, write policy snippets, soak net-new. |
| [`scripts/`](../../scripts/) | Bash entry points: two-host setup, compile, demo, soak checks. |
| [`scripts/lib/`](../../scripts/lib/) | Shared code **sourced** by other scripts (not usually run alone). |
| [`ansible/`](../../ansible/) | Playbooks that install `.pp`, soak monitor, enforce, rollback (role **`selinux_pac`**). |
| [`packaging/`](../../packaging/) | RPM specs (`selinux-policy-ops`, `<app>-selinux`) and compile container. |
| [`docs/`](../) | Guides: `training/` (learn), `demo/` (talks, this page, and tests), `admin/` (ship). |
| [`policy_out/`](../../policy_out/) | Generated output on your machine (gitignored). |
| [`.github/workflows/`](../../.github/workflows/) | PR CI: `forbidden-patterns` + `version-consistency`. Ship is AAP / Mac ansible-playbook. |
| [`tests/fixtures/`](../../tests/fixtures/) | Small policy snippets used to test the blast-radius classifier in CI. |

---

## Application layer (`demo/shopapi/`)

**Why `demo/shopapi/` exists:** that is the live generate target (Spring Boot, `SELinuxContext=shopapi_t`, first-ship `/health` `/state` `/log`, outage `/feature-spool`).

| File | What it does (simply) |
|------|------------------------|
| **`demo/shopapi/`** | JVM on port **8091** (from `config/shopapi.manifest.yml`). |
| **`demo/shopapi/shopapi.service`** | systemd unit with `SELinuxContext=shopapi_t` and a private JRE launcher. |

**Why three first-ship HTTP paths?** `/health` (bind), `/state` (var_lib), `/log` (logs). When policy is incomplete, you get an AVC that points to the **missing allow rule**. **Deploy gates** use [`scripts/wait_for_endpoints.sh`](../../scripts/wait_for_endpoints.sh) to curl those paths and confirm the process still runs as the right **domain**.

---

## Policy source (`selinux/`)

| File | What it is |
|------|------------|
| **`myapp.te`** | Human-readable rules: types, `allow` lines, and reusable **macros** from refpolicy. |
| **`myapp.fc`** | “This path on disk should have type X.” Used by `restorecon`. |
| **`policy_version.txt`** | Version number (must match the `policy_module(myapp, …)` line in `.te`; CI checks this). |
| **`payments/`** | Example second application module (see [Add an application](#add-an-application)). |

**Review tip:** prefer **interface macros** (shared refpolicy helpers) over one-off allows copied from `audit2allow`. That matches what [`scripts/validate_forbidden_patterns.sh`](../../scripts/validate_forbidden_patterns.sh) enforces in CI.

---

## Config and manifests (`config/`)

**Problem manifests solve:** scripts used to assume every app was named `myapp` and lived under `/opt/myapp`. That caused **wrong AVC filters** for other apps.

| File | Role |
|------|------|
| **`myapp.manifest.yml`** | Offline generator fixture: paths, domains (deterministic goldens). |
| **`payments.manifest.example.yml`** | Template for a second app. |
| **`README.md`** | Field descriptions. |

**Loader:** [`scripts/lib/app_manifest.py`](../../scripts/lib/app_manifest.py)

- **`validate`** — checks required YAML keys.
- **`shell-export`** — prints variables bash scripts can `eval` (domains, path list for AVC filtering, HTTP port, etc.).
- **`resolve`** — finds manifest from `APP_MANIFEST` or `POLICY_APP`.

Scripts like **`monitor_avc.sh`** and **`export_app_avcs_to_file`** in **`lib/avc_query.sh`** require manifest-derived paths — they **fail loudly** if paths are missing instead of silently using myapp defaults.

---

## Python CLI (`cli/`) — turning AVC logs into policy edits

Generation starts the same way every time: read the log, merge duplicate lines, subtract permissions already in `.te`.

### Shared preprocessing — `avc_preprocess.py`

| Step | Plain English |
|------|----------------|
| Parse AVC lines | Extract who tried what (source type, target type, permission class). |
| Merge | Combine duplicate lines into one row with all permissions. |
| Subtract existing | Drop permissions already allowed in current `myapp.te`. |
| **Net-new** | What is left is what generation must address. |

### `deterministic_gen.py`

For each net-new denial it assigns a **verdict** (fix file labeling, use a boolean, add a safe allow via sepolgen, refuse dangerous allows, etc.) and writes:

- Updated **`policy_out/myapp.te`** / **`.fc`**
- **`findings.json`** — machine-readable record of each decision
- **`pr_summary.md`** — text for humans

Run golden tests: **`bash scripts/run_deterministic_fixtures.sh`**. Payments must not leak `myapp` strings: **`bash scripts/run_deterministic_payments_check.sh`**.

Details: [Generate a module](#generate-a-module).

### Other CLI modules (short)

| Module | Role |
|--------|------|
| **`fc_labeling.py`** | Detect labeling drift vs new `.fc` lines. |
| **`policy_rules.py`** | Shared forbidden-target lists, `NEEDS_REVIEW_RULES`, and verdict constants. |
| **`verify_avc_coverage.py`** | Checks generated policy covers the exported AVC set (PR/candidate `.te`). |
| **`soak_net_new.py`** | Soak: net-new needs vs **installed** policy (`sesearch`), JSON exceptions. |
| **`boolean_hints.yml`** (in `config/`) | Curated hints when a **setsebool** is the right fix. |

---

## Shell scripts (`scripts/`) — what to run when

Most scripts expect your shell’s **current directory** to be the **repo root** unless the doc says otherwise. Staging and demo scripts need **RHEL + SELinux** (dev box). Compile natively with `selinux-policy-devel` on RHEL.

### Day-to-day developer commands

| Script | When you use it |
|--------|------------------|
| **`dev_generate_policy.sh`** | Main command: vendor-policy pre-flight → export AVCs → generate → diff → optional copy into `selinux/`. `--tune-report` for vendor-covered apps (commands only). `--force "reason"` only if the app genuinely differs. |
| **`selinux_pac_adopt.sh`** | `doctor` + `init APP` — print manifest and **Ansible** next steps. |
| **`setup_rhel_hosts.sh`** | Write `inventory.dev.yml` / `inventory.production.yml`; ping; doctor; bootstrap hints. |
| **`demo_present.sh`** | Customer talk (~20 min, one host): Act 0 triage, App A (vendor, already enforcing), App B (tune, no `.te`), shopapi generate. `--profile customer` = 0–3; `technical` adds PR + a pointer at `demo_e2e_mac.sh`. `--preflight` FAILs if App B is already tuned. |
| **`demo_bootstrap.sh`** / **`make demo-bootstrap`** | Idempotent three-app estate on RHEL. JWS if the repo is reachable, else distro Tomcat + `tomcat_t`. |
| **`demo_e2e_mac.sh`** / **`demo_e2e_rhel_qa.sh`** / **`demo_e2e_rhel_prod.sh`** | Three-host **shopapi** pipeline (~45 min): generate → PR on `selinux/shopapi/` → clean soak → enforce; `/feature-spool` fails on prod; admin rollback. Not the first customer conversation. `demo_e2e_rhel_dev.sh` is a deprecated name for the QA script (remove after 2026-12-31). |
| **`reset_demo_vms.sh`** | Between rehearsals: unload leftover `shopapi` modules and prod RPMs; **untune App B** (port 8090, `/opt/appdata` fcontext, connect boolean). JVM stays. Then start the Mac conductor or `demo_present.sh --preflight`. Not `reset_host_state.yml`. |
| **`demo_open_generated_pr.sh`** | Open a GitHub PR from live generated `selinux/` (Mac, after scp from rhel-qa). |
| **`assemble_pr_body.sh`** | Builds GitHub PR description from template + summary + optional rule diff. |
| **`compile_and_validate.sh`** | Compile `.te`/`.fc` to `.pp` and run basic checks. |

**Environment tips:**

- **`APP_MANIFEST`** / **`POLICY_APP`** — pick which manifest drives paths and names
### Safety gates (soak and production)

| Script | Plain English |
|--------|----------------|
| **`monitor_avc.sh`** | Soak report: raw AVC count **and** net-new vs installed policy (`--max-net-new`). Needs **`--manifest`**. |
| **`check_soak_ready.sh`** | Manual host CLI: days elapsed, AVC/net-new, deploy report. Ansible uses **`collect_soak_facts.sh`**. |
| **`collect_soak_facts.sh`** | JSON facts for Ansible (`avc_net_new_count`, `avc_fail_closed`). |
| **`post_deploy_report.sh`** | Writes deploy report JSON after endpoints are exercised. |
| **`verify_file_contexts.sh`** | Compare on-disk labels to `.fc` before restart. |

### Compile toolchain

| Script / lib | Role |
|--------------|------|
| **`lib/compile_policy.sh`** | Compile module with `selinux-policy-devel` (`make -f /usr/share/selinux/devel/Makefile`). |
| **`compile_and_validate.sh`** | Forbidden-pattern check + compile. |
| **`ci/install_rhel_policy_tools.sh`** | `dnf install` devel + setools on a RHEL/Stream box (optional; not a GitHub job). |

### CI-heavy scripts (you may read, rarely run locally)

| Script | Why it exists |
|--------|----------------|
| **`validate_forbidden_patterns.sh`** | Block wildcards and risky allows in `.te`. |
| **`validate_policy_semantics.sh`** | After compile, probe policy in an isolated store (e.g. no shadow read). |
| **`validate_version_consistency.sh`** | Version file matches `.te` and packaging. |
| **`classify_policy_blast_radius.sh`** | Suggest soak length from how risky new allows are. |
| **`lib/policy_module_diff.sh`** | Markdown diff of allow rules between two module versions (for PR comments). |
| **`smoke_test.py`** | Fast regression suite on Ubuntu CI. |
| **`run_e2e_tests.sh`** | Broader integration driver. |

### Demo helpers

| Script | Role |
|--------|------|
| **`demo_present.sh`** | Customer talk, one host (~20 min). |
| **`demo_bootstrap.sh`** | Idempotent App A/B + shopapi estate (`make demo-bootstrap`). |
| **`demo_e2e_mac.sh`**, **`demo_e2e_rhel_qa.sh`**, **`demo_e2e_rhel_prod.sh`** | Three-host pipeline of [203-RHEL_TWO_HOST.md](203-RHEL_TWO_HOST.md) (~45 min). |
| **`reset_demo_vms.sh`** | Wipe leftover shopapi policy and untune App B (Mac). JVM stays. |
| **`demo_open_generated_pr.sh`** | Live generate → GitHub PR (needs `gh`). |

---

## Ansible (`ansible/`)

Playbooks are short; behavior lives in the **`selinux_pac`** role (manifest-driven ports and units).

| Playbook | Phase |
|----------|--------|
| **`deploy_canary.yml`** | Install module, permissive domain, smoke endpoints, start soak clock. |
| **`soak_monitor.yml`** | Daily / on-demand: fail if net-new exceeds threshold. Talk: first-ship only so this **passes**. |
| **`soak_status.yml`** | Read-only soak facts before enforce. |
| **`enforce_production.yml`** | Soak gates passed → enforcing mode. |
| **`emergency_rollback.yml`** | Break-glass rollback steps. |
| **`reset_host_state.yml`** | Interrupted canary: `semodule -B` + clear permissive. Module stays. Demo wipe is `reset_demo_vms.sh`. |

**Canary (simplified):** load manifest → validate artifact → optional `semodule -DB` → register **`selinux_ports`** → permissive domain → install `.pp` → `restorecon` → restart services → write marker + report.

**Enforce (simplified):** `collect_soak_facts` (prefer **net-new**) → remove permissive → rebuild policy store → smoke again.

Inventory examples: **`inventory.dev.example.yml`** (RHEL dev), **`inventory.production.example.yml`** (RHEL prod). Generate with **`scripts/setup_rhel_hosts.sh`**. AAP objects: [`ansible/aap/`](../../ansible/aap/) and [301-ANSIBLE_OPERATIONS.md](../admin/301-ANSIBLE_OPERATIONS.md). Denial after ship: [301-ANSIBLE_OPERATIONS.md#a-denial-after-ship](../admin/301-ANSIBLE_OPERATIONS.md#a-denial-after-ship). Two-host walkthrough: [203-RHEL_TWO_HOST.md](203-RHEL_TWO_HOST.md).

---

## Packaging (`packaging/`)

| Artifact | Purpose |
|----------|---------|
| **`myapp-selinux.spec`** | Test-fixture RPM for the offline `myapp` generator module. |
| **`shopapi-selinux.spec`** | Demo RPM: compiled `shopapi.pp` + `/etc/shopapi/selinux-manifest.yml`. |
| **`selinux-policy-ops.spec`** | RPM of operational scripts (`monitor_avc.sh`, `soak_net_new.py`, `collect_soak_facts.sh`, …) at `/usr/libexec/selinux-policy-ops`. |

---

## GitHub review (no Actions in the paced lab)

The two-host talk track opens a **GitHub PR** with `scripts/demo_open_generated_pr.sh` so CODEOWNERS can review `selinux/shopapi/`. GitHub Actions workflows are not part of that demo.

PR checklist template: [`.github/PULL_REQUEST_TEMPLATE/selinux_policy_review.md`](../../.github/PULL_REQUEST_TEMPLATE/selinux_policy_review.md).

---

## Tests (`tests/`)

**Blast-radius fixtures** under **`tests/fixtures/blast_radius/`** — tiny `.te` changes with expected JSON (tier, soak days, fail-closed). CI ensures the classifier does not silently shorten soak time on errors.

**Deterministic golden AVCs** live under **`docs/examples/fixtures/deterministic/`** (contiguous **`01`–`13`**; every verdict type has at least one case).

---

## Suggested path for new contributors

1. Type **[101](../training/101-SELINUX.md)** on a SELinux VM (**[102](../training/102-SELINUX_BASICS.md)** §1–4 if labels are fuzzy).
2. Watch **[202](202-DEMO_GUIDE.md)**.
3. Skim [README.md](../../README.md) architecture diagram.
4. Open **`config/shopapi.manifest.yml`** and **`demo/shopapi/`** — match each first-ship path to a permission story. Generator goldens live in **`selinux/myapp.te`**.
5. Trace one AVC through **`cli/avc_preprocess.py`**, then try **`bash scripts/dev_generate_policy.sh --skip-export`** with a saved **`policy_out/avc.log`**.
6. When ready to ship: **[301](../admin/301-ANSIBLE_OPERATIONS.md)**.

---

## Quick reference — algorithms in one line each

| Idea | One-line explanation |
|------|----------------------|
| AVC merge | Group log lines by source + target + class; union permissions. |
| Net-new | Permissions in AVC minus permissions already in `.te`. |
| Policy diff for PRs | Compile old and new module → compare `sesearch` allow lines. |
| Blast radius | Classify each **new** allow as low/medium/high risk → suggested soak days; errors → stay strict (7 days). |
| Soak gate | Enough days since canary + **zero net-new access needs** vs installed policy (raw AVC fallback if `sesearch` missing) + deploy report OK. |
| Version SSOT | `policy_version.txt` must match `policy_module()` in `.te`. |
| Manifest identity | App name, domains, and AVC path filters come from YAML — not silent `myapp` defaults. |

---

## Generate a module

`dev_generate_policy.sh` classifies each denial with the house rules in `cli/policy_rules.py`. CI uses the same classifier.

```mermaid
flowchart TD
  start["dev_generate_policy.sh"] --> vendor{"Vendor module already covers this app?"}
  vendor -->|yes| tune["Stop. --tune-report prints host commands. No .te"]
  vendor -->|no| class["Classify each AVC"]
  class --> fc["fc_fix or fc_drift: label, then restorecon"]
  class --> allow["direct or interface: one allow"]
  class --> block["forbidden or needs_review: stop unless you pass the flag"]
```

| Situation | What you do |
|-----------|-------------|
| `loaded` / `base_policy` | Vendor or targeted policy already confines this app. `--tune-report`. Do not generate a second module. |
| `package_installed` / `package_available` / `unconfined` | Install or enable the vendor RPM (`jws6-tomcat-selinux`, `eap*-selinux`). Do not generate. |
| `none` | No vendor module (shopapi, Node, Spring Boot). Generation continues. |
| Laptop, no `semodule` | One skip line. Offline fixtures still run. |

`--tune-report` writes `policy_out/tune_report.md` and never a `.te`. `--force "reason"` is the only bypass, and the reason lands in the PR. Bare `--force` is rejected.

| Verdict | Meaning |
|---------|---------|
| `fc_fix` | Path is in the manifest and not in `.fc` yet. Add a line, then `restorecon`. |
| `fc_drift` | `.fc` already covers the path. `restorecon` only. |
| `private_port` | `name_bind` on a shared port type. Use the app's `_port_t`. |
| `boolean` | A switch already in policy. `setsebool -P`, not a new allow. |
| `interface` | A refpolicy macro matched (`sepolgen-ifgen` on the RHEL box). |
| `direct` | A module-private type, or no macro fit. |
| `baseline` | Already in the `.te` or a baseline macro. `cgroup_t` getattr is omitted on purpose. |
| `needs_review` | Domain-weakening (`execmem`, `dac_override`). Not written unless `--allow-needs-review`. |
| `forbidden` | Refused (`shadow_t`, and the same patterns CI rejects). |
| `toolchain_required` | A base type, and interface matching is not installed. Pass `--allow-degraded` only if you mean that. |

Classify one fixture without compiling:

```bash
python3 cli/deterministic_gen.py --explain \
  --avc-log docs/examples/fixtures/deterministic/01-mislabeled-var-lib/avc.log \
  --manifest config/myapp.manifest.yml \
  --existing-te selinux/myapp.te \
  --existing-fc selinux/myapp.fc
```

Goldens: `make test-fixtures` (`docs/examples/fixtures/deterministic/`, cases `01`–`13`). Ship after the PR is [301](../admin/301-ANSIBLE_OPERATIONS.md).

## Add an application

Customer policy lives in **the application repo**, not in this one. Generate on **rhel-qa**. Prod never clones git. This repo is the generator, the CI helpers, and the AAP jobs. `selinux/myapp.te` is an offline golden. The live demo module is `selinux/shopapi/`.

```text
app repo  --deploy-->  rhel-qa  --generate-->  PR on the app repo
app repo  --merged-->  RPM  --AAP canary-->  rhel-prod
```

`payments` is the second module you can practice **in this clone**:

```bash
cp config/payments.manifest.example.yml config/payments.manifest.yml
bash scripts/validate_app_manifest.sh config/payments.manifest.example.yml
bash scripts/scaffold_sepolicy_module.sh payments payments_t
POLICY_MODULE=payments SELINUX_DOMAIN=payments_t \
  bash scripts/compile_and_validate.sh selinux/payments
```

`scaffold_sepolicy_module.sh` will not overwrite a `.te` that is already in git. The checked-in `payments.if` publishes `payments_read_public_state` and `payments_domtrans` for other modules. Manifest field that matters: `policy.module_dir: selinux/payments`.

## What a pull request must not contain

CI rejects these. The generator is supposed to refuse them first.

| Do not write | Why |
|--------------|-----|
| A custom module for JWS, EAP, httpd, named, or postgresql | Vendor or base policy already confines them. Tune, do not duplicate. |
| `allow … self:process execmem` or `dac_override` without the review flag | Domain-weakening. `needs_review` blocks until `--allow-needs-review`. |
| `allow … unreserved_port_t:tcp_socket name_bind` | Binds every high port. Use the app's port type. |
| `allow … bin_t:file execute` | Label the binary with the app exec type. |
| `allow … *:*` or `self:*` | Unbounded. |
| `chcon` in a playbook | Lost on the next `restorecon`. |
| `setenforce 0` for one app | Host-wide. Use `semanage permissive -a` for that domain. |
| `audit2allow` pasted in | Wildcards and the wrong class. |

File-context lines for directories do not use `--` (that means regular file only). Cover `/run/app` and `/var/run/app`. Split a Python venv: the interpreter is the exec type, the rest is the lib type.

Review checklist for a policy PR:

- Interfaces, not a raw `audit2allow` dump
- Dedicated port types, not `unreserved_port_t`
- `.fc` uses FHS paths and has no `--` on directories
- `forbidden-patterns` and `version-consistency` are green
- `selinux/policy_version.txt` matches `policy_module()` in the `.te`
- Compile happened on RHEL (`compile_and_validate.sh`), not on a laptop
- A denial after ship is a new PR ([301](../admin/301-ANSIBLE_OPERATIONS.md#a-denial-after-ship)), not `semodule -i` on prod

## The other guides

| Guide | For |
|-------|-----|
| [101](../training/101-SELINUX.md) | Type the shopapi labs |
| [102](../training/102-SELINUX_BASICS.md) | Read the words |
| [202](202-DEMO_GUIDE.md) | The 20-minute customer talk |
| [203](203-RHEL_TWO_HOST.md) | The three-host ship talk |
| [204](204-TESTING.md) | `make check` |
| [301](../admin/301-ANSIBLE_OPERATIONS.md) | Canary, soak, enforce |

If this guide disagrees with the code, trust the repository and send a PR to update the doc.
