# SELinux PaC documentation

Four folders, in reading order. **training** is concepts, commands, files, and a module typed by hand. **tool** is the scripts that run those commands. **demo** is the talks. **admin** is how you ship.

| Folder | Start |
|--------|--------|
| [training/](training/101-CONCEPTS.md) | **[101](training/101-CONCEPTS.md)** then **[102](training/102-COMMANDS.md)**, **[103](training/103-CONFIG-FILES.md)**, **[104](training/104-HAND-BUILT-MODULE.md)** |
| [tool/](tool/201-TOOL-COMMANDS.md) | **[201](tool/201-TOOL-COMMANDS.md)** then **[202](tool/202-TOOL-LAB.md)** |
| [demo/](demo/301-CUSTOMER.md) | **[301](demo/301-CUSTOMER.md)** (20 min), **[302](demo/302-TECHNICAL.md)** (45 min), **[303](demo/303-TESTING.md)** |
| [admin/](admin/401-OPERATIONS.md) | **[401](admin/401-OPERATIONS.md)** canary, soak, enforce |

| Pattern | Meaning |
|---------|---------|
| **Why** | What real problem this step solves |
| **Where** | Which machine and directory (controller vs RHEL server vs repo root) |
| **What / good sign** | What the command does and how you know it worked |

**Terms** are in **[101](training/101-CONCEPTS.md)**. **Commands** are in **[102](training/102-COMMANDS.md)**.

| You are | Start here |
|---------|------------|
| **New to SELinux** | **[101](training/101-CONCEPTS.md)** → **102** commands → **202** |
| **RHEL admin (customer env)** | **[401](admin/401-OPERATIONS.md)** |
| **Trying this on a Mac** | [../README.md](../README.md#try-it-on-a-mac) — two RHEL VMs + `setup_rhel_hosts.sh` |
| **Laptop only (no VM)** | [202 — laptop](tool/202-TOOL-LAB.md#laptop-no-selinux) + `make check` (**303**) |

---

## Catalog

| # | Guide | You need |
|---|--------|----------|
| **101** | [Concepts](training/101-CONCEPTS.md) | Labels, enforcing, an AVC line. Commands: `getenforce`, `ls -Z`, `ps -eZ` |
| **102** | [Commands](training/102-COMMANDS.md) | One question per command: mode, labels, ports, booleans, modules, policy query, audit |
| **103** | [Config files](training/103-CONFIG-FILES.md) | The files those commands read and write, including module priority |
| **104** | [Hand-built module](training/104-HAND-BUILT-MODULE.md) | Shopapi labs with the commands from **102**. No repo script |
| **201** | [Tool commands](tool/201-TOOL-COMMANDS.md) | Each script and playbook, the commands it runs, and which **104** steps it replaces |
| **202** | [Tool lab](tool/202-TOOL-LAB.md) | The **104** outcome using the scripts |
| **301** | [Customer talk](demo/301-CUSTOMER.md) | `demo_present.sh` — one host, ~20 min. Finish **104** first |
| **302** | [Two Linux VMs](demo/302-TECHNICAL.md) | `demo_e2e_*.sh` — three windows, ~45 min |
| **303** | [Testing](demo/303-TESTING.md) | `make check`, CI, endpoints |
| **401** | [Ship the module](admin/401-OPERATIONS.md) | Canary, soak, enforce, and a denial after ship |

`make training-lab` prints the 301 talk and runs nothing. It is not a third lab.

**Contributors (no SELinux on laptop):** from repo root run `make check` — **303**.

Samples (not numbered): [examples/README.md](examples/README.md). App manifest schema: [../config/README.md](../config/README.md). Ansible playbooks: [../ansible/README.md](../ansible/README.md). New app: `bash scripts/selinux_pac_adopt.sh init <app>` ([201 — Add an application](tool/201-TOOL-COMMANDS.md#add-an-application)). Repo entry: [../README.md](../README.md).
