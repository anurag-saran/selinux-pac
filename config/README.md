# App manifest

Each application onboarded to the SELinux Policy-as-Code pipeline declares an **app manifest** — a YAML file that drives readiness checks, deploy reports, Ansible facts, and inventory defaults.

**Why manifests exist:** scripts and Ansible need one place for app name, paths, domains, **bind ports**, and HTTP probes — so nothing silently assumes **`myapp`**.

**Ports vs IPs:** keep **bind port numbers** in the committed manifest (`http.port`, `selinux_ports`) so they stay the same in every environment. Change **probe host / VIP** per env (`http.host` or Ansible `http_probe_host`). Do not retune listen ports when promoting code between staging and production unless you also update policy and the canary `semanage port -a` step.

**Where you edit files:** `config/<app>.manifest.yml` in your **git clone** (repo root). **Where validation runs:** same machine as your shell at repo root (`validate_app_manifest.sh`, CI).

**More context:** [203-RHEL_TWO_HOST.md](../docs/demo/203-RHEL_TWO_HOST.md), [201 — Add an application](../docs/demo/201-CODE_WALKTHROUGH.md#add-an-application), [301-ANSIBLE_OPERATIONS.md](../docs/admin/301-ANSIBLE_OPERATIONS.md), [301-ANSIBLE_OPERATIONS.md#a-denial-after-ship](../docs/admin/301-ANSIBLE_OPERATIONS.md#a-denial-after-ship) (denied port → `selinux_ports`, not live `semanage port`), [docs/README.md](../docs/README.md).

## Quick start

```bash
bash scripts/selinux_pac_adopt.sh init payments
```

1. Copy [`payments.manifest.example.yml`](payments.manifest.example.yml) to `config/<app_name>.manifest.yml`.
2. Fill in paths, systemd units, HTTP probes, and SELinux port types (**same bind ports in every env**).
3. Scaffold policy on RHEL: `bash scripts/scaffold_sepolicy_module.sh payments payments_t` (see [201 — Add an application](../docs/demo/201-CODE_WALKTHROUGH.md#add-an-application)).
4. Point scripts and Ansible at it:

```bash
export APP_MANIFEST=config/payments.manifest.yml
bash scripts/wait_for_endpoints.sh --manifest "$APP_MANIFEST"
bash scripts/validate_app_manifest.sh config/payments.manifest.yml
```

Default (when `APP_MANIFEST` is unset): `config/${POLICY_APP:-myapp}.manifest.yml` (offline generator golden). Demo JVM: [`shopapi.manifest.yml`](shopapi.manifest.yml) (`--app-name shopapi`).

## Schema

| Key | Required | Description |
|-----|----------|-------------|
| `app_name` | yes | Module prefix (`payments` → `payments_t`, `payments_port_t`) |
| `domain` | yes | Primary process domain |
| `paths.install_root` | yes | Application install tree |
| `paths.var_dir` | yes | State directory (`StateDirectory`) |
| `paths.log_dir` | recommended | Log directory (`LogsDirectory`) |
| `paths.runtime_dir` | recommended | Runtime dir (`RuntimeDirectory`) |
| `services.primary.unit` | yes | Main systemd unit |
| `services.primary.domain` | no | Defaults to `domain` |
| `services.backend` | no | Second unit (microservice / sidecar) |
| `http.host` | no | Probe target (default `127.0.0.1`). **Change per environment** — not a bind address for policy. |
| `http.port` | yes | App **bind** port (same in every env); also used for probes |
| `http.endpoints` | yes | Path list (GET, expect HTTP 200) |
| `http.backend.port` | if backend | Backend health port |
| `http.backend.health_path` | if backend | Default `/health` |
| `selinux_ports` | recommended | Port → type for canary `semanage port -a` (stable across env) |
| `selinux_booleans` | no | List of `{name, state, persistent}`. Canary applies each with `ansible.posix.seboolean` before the service starts. `tomcat_can_network_connect` is rejected. `httpd_can_network_connect` is rejected on a Tomcat domain. |
| `policy.module_dir` | no | Default `selinux` |
| `deploy.soak_marker_file` | no | Default `/var/lib/selinux-policy-ops/{app}/selinux_canary_deployed_at` |
| `deploy.deploy_report_file` | no | Default `/var/lib/selinux-policy-ops/{app}/selinux_deploy_report.json` |

## What reads the manifest

| Consumer | Purpose |
|----------|---------|
| [`scripts/wait_for_endpoints.sh`](../scripts/wait_for_endpoints.sh) | systemd units, HTTP probes, domain verification |
| [`scripts/post_deploy_report.sh`](../scripts/post_deploy_report.sh) | Deploy JSON service/domain fields |
| [`scripts/check_soak_ready.sh`](../scripts/check_soak_ready.sh) | Domain context keys in deploy report; optional **`--auto-tier`** with policy pair paths |
| Ansible role `selinux_pac` | Loads manifest on the target: ports, units, paths, probe host |
| [`cli/deterministic_gen.py`](../cli/deterministic_gen.py) | `--manifest` for path → `.fc` labeling rules (`fc_fix` / `fc_drift`) |
| [`cli/soak_net_new.py`](../cli/soak_net_new.py) | Domains for net-new soak vs installed policy |
| [`scripts/validate_app_manifest.sh`](../scripts/validate_app_manifest.sh) | CI / onboarding validation |
| [`config/registered_apps.example.yml`](registered_apps.example.yml) | Optional multi-app registry for soak loops |

## Designing probes for a new app

1. List SELinux surfaces the app touches (files, ports, IPC, scripts).
2. Map each surface to an entry in `http.endpoints` (the probe canary curls).
3. Always include `services.primary` and real health path(s).
4. Run staging permissive → export AVCs → generate policy (`bash scripts/dev_generate_policy.sh`; default **`deterministic_gen.py`**, optional `--engine llm`).

See [`docs/demo/204-TESTING.md`](../docs/demo/204-TESTING.md) for the full test-layer model.

## Ansible inventory

**Two-host inventories:** `bash scripts/setup_rhel_hosts.sh write --dev-host … --prod-host …` ([203-RHEL_TWO_HOST.md](../docs/demo/203-RHEL_TWO_HOST.md)).

**Laptop / AAP controller → RHEL target** (two-host lab). `playbook_dir` is the controller path — use it only for artifacts copied onto the host:

```yaml
vars:
  app_name: payments
  policy_artifact_dir: "{{ playbook_dir }}/.."
  policy_pp_src: "{{ policy_artifact_dir }}/selinux/{{ app_name }}.pp"
  app_manifest_path: /home/ansible/selinux-pac/config/payments.manifest.yml
  selinux_ops_from_package: false
  selinux_ops_dir: /home/ansible/selinux-pac/scripts
  install_root: /opt/payments
  var_dir: /var/lib/payments
  log_dir: /var/log/payments
  domain: payments_t
```

**Ansible on the same host** (`connection: local`) may use `playbook_dir` for `selinux_ops_dir` and `app_manifest_path`.

**Production:** install `<app>-selinux` RPM — manifest at **`/etc/<app>/selinux-manifest.yml`**. Keep bind ports in the manifest; set `http_probe_host` (or `http.host`) to the canary IP/VIP. Module SemVer is read from **`selinux/policy_version.txt`** under `policy_artifact_dir` (not duplicated in inventory).
