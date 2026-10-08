# SELinux PaC documentation

Three folders. **training** is the lab. **demo** is the talks and how the tool works. **admin** is how you ship.

| Folder | Start |
|--------|--------|
| [training/](training/101-CONCEPTS.md) | **[101](training/101-CONCEPTS.md)** concepts, then the command catalog and the hand-built lab |
| [demo/](demo/202-DEMO_GUIDE.md) | **[202](demo/202-DEMO_GUIDE.md)** (20 min) then **[203](demo/203-RHEL_TWO_HOST.md)** (45 min). **[201](demo/201-CODE_WALKTHROUGH.md)** is the code map. **[204](demo/204-TESTING.md)** is `make check`. |
| [admin/](admin/301-ANSIBLE_OPERATIONS.md) | **[301](admin/301-ANSIBLE_OPERATIONS.md)** canary, soak, enforce |

| Pattern | Meaning |
|---------|---------|
| **Why** | What real problem this step solves |
| **Where** | Which machine and directory (controller vs RHEL server vs repo root) |
| **What / good sign** | What the command does and how you know it worked |

**Terms** like domain, AVC, `.te`, and **`semanage`** are defined in **[102](training/102-SELINUX_BASICS.md)**.

| You are | Start here |
|---------|------------|
| **New to SELinux** | **[101](training/101-CONCEPTS.md)** → **102** commands → **202** |
| **RHEL admin (customer env)** | **[301](admin/301-ANSIBLE_OPERATIONS.md)** |
| **Trying this on a Mac** | [../README.md](../README.md#try-it-on-a-mac) — two RHEL VMs + `setup_rhel_hosts.sh` |
| **Laptop only (no VM)** | **101** [Appendix B](training/101-SELINUX.md#appendix-b-laptop-no-selinux) + `make check` (**204**) |

---

## Catalog

| # | Guide | You need |
|---|--------|----------|
| **101** | [Concepts](training/101-CONCEPTS.md) | Labels, enforcing, an AVC line. Commands: `getenforce`, `ls -Z`, `ps -eZ` |
| **102** | [SELinux basics](training/102-SELINUX_BASICS.md) | What the words mean (lab 0 is §1–4) |
| **202** | [Customer talk](demo/202-DEMO_GUIDE.md) | `demo_present.sh` — one host, ~20 min. Finish **101** first |
| **203** | [Two Linux VMs](demo/203-RHEL_TWO_HOST.md) | `demo_e2e_*.sh` — three windows, ~45 min |
| **201** | [How the tool works](demo/201-CODE_WALKTHROUGH.md) | Folders, generate, a second app, what a PR must not contain |
| **204** | [Testing](demo/204-TESTING.md) | `make check`, CI, endpoints |
| **301** | [Ship the module](admin/301-ANSIBLE_OPERATIONS.md) | Canary, soak, enforce, and a denial after ship |

`make training-lab` prints the 202 talk and runs nothing. It is not a third lab.

**Contributors (no SELinux on laptop):** from repo root run `make check` — **204**.

Samples (not numbered): [examples/README.md](examples/README.md). App manifest schema: [../config/README.md](../config/README.md). Ansible playbooks: [../ansible/README.md](../ansible/README.md). New app: `bash scripts/selinux_pac_adopt.sh init <app>` ([201 — Add an application](demo/201-CODE_WALKTHROUGH.md#add-an-application)). Repo entry: [../README.md](../README.md).
