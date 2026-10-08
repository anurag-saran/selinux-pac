# 103 — SELinux config files

The commands that read and write these files are in [102](102-COMMANDS.md). None of this is a repo script. Paths are the RHEL 9 layout. A directory listing that has not been captured on rhel-qa is in [LIVE_CHECKS.md](../LIVE_CHECKS.md).

File contexts are files on disk. `restorecon` and `matchpathcon` read them. They are not part of the kernel.

---

## /etc/selinux/config

**What it holds.** The mode to use at boot (`SELINUX=enforcing`) and the policy name (`SELINUXTYPE=targeted`).

**Which command writes it.** An editor. `setenforce` does not. `getenforce` and `sestatus` read the running mode, which can differ until reboot.

**Look safely.** `cat /etc/selinux/config`. Do not change `SELINUX=disabled`.

---

## The module store

**What it holds.** `/var/lib/selinux/targeted/active/` is the policy the kernel is using after the last rebuild. Under it:

| Path | What |
|------|------|
| `modules/100` | Base modules shipped with the policy |
| `modules/200` | Modules from an RPM |
| `modules/400` | Modules from `semodule -i`, and local changes from `semanage` (a permissive domain, a port, a file context, a boolean) |
| `policy.kern` | The rebuilt binary policy `sesearch` and `seinfo` can read when `/sys/fs/selinux/policy` is not the file you want |

**Which command writes it.** `semodule -i` writes priority 400 and rebuilds `policy.kern`. `semanage` writes its own small modules at 400 and rebuilds the same way. An RPM's `%post` installs its `.pp` at priority 200. `semodule -B` and `semodule -DB` rebuild `policy.kern` without adding a module.

**Look safely.** `sudo semodule --list-modules=full`. `sudo ls /var/lib/selinux/targeted/active/modules`. Do not delete a directory under `modules/`.

**Priority gotcha.** A hand-run `semodule -i` stores the module at 400. If an RPM already installed the same module name at 200, the 400 copy wins and the RPM's copy is ignored. A later `dnf update` refreshes priority 200 and leaves the 400 module in place. `semodule -l` does not show this. `semodule --list-modules=full` does. Remove the override with `semodule -X 400 -r name` only when you mean to fall back to the RPM. Production day 0 installs the RPM. It does not `semodule -i` the shopapi package onto the server.

---

## policy.33

**What it holds.** The binary policy file shipped for targeted policy on RHEL 9, at `/etc/selinux/targeted/policy/policy.33`. The number is the policy version. It is the packaged file. After `semodule` or `semanage` rebuilds the store, the kernel loads the rebuilt image, not this file by itself.

**Which command writes it.** The `selinux-policy-targeted` RPM. Do not compile over it.

**Look safely.** `ls -l /etc/selinux/targeted/policy/policy.33`. Confirm the filename on the host with the command in [LIVE_CHECKS.md](../LIVE_CHECKS.md). `sesearch` can take this path when you want the packaged policy rather than the rebuilt store.

---

## file_contexts and file_contexts.local

**What they hold.** Under `/var/lib/selinux/targeted/active/`:

| File | What |
|------|------|
| `file_contexts` | The combined map from the loaded modules: path pattern to label |
| `file_contexts.local` | Lines `semanage fcontext -a` added on this host |

`file_contexts.homedirs` and `file_contexts.bin` sit beside them. The text files are the ones to read. `matchpathcon` and `restorecon` read this map. The kernel does not store it as a list of paths.

**Which command writes them.** A module install rebuilds `file_contexts` from every module's `.fc`. `semanage fcontext -a` and `-d` write `file_contexts.local`. `semanage export` prints those local lines.

**Look safely.**

```bash
sudo semanage fcontext -l -C
sudo semanage export
```

`semanage export` only reads. Do not edit `file_contexts` with a text editor. The next rebuild replaces it.

---

## /sys/fs/selinux

**What it holds.** The kernel's selinuxfs. `policy` is the binary the kernel is enforcing. `enforce` is the mode `getenforce` reads. Booleans appear as files under `booleans/`.

**Which command writes it.** The kernel, when a policy is loaded. `setenforce` writes `enforce`. This project does not.

**Look safely.** `ls /sys/fs/selinux`. `cat /sys/fs/selinux/enforce` prints `1` when the machine is Enforcing. Do not write that file. There is no selinuxfs inside a container that is not running with SELinux, which is why the soak tool fails closed instead of pretending the policy was read.

---

## The audit log

**What it holds.** `/var/log/audit/audit.log` is the file `auditd` writes. AVC lines are one kind of record. Rotated files are `audit.log.1` and friends. `ausearch` reads the set.

**Which command writes it.** `auditd`, not `ausearch`. `ausearch` only reads.

**Look safely.** `sudo ausearch -m avc -ts recent --subject shopapi_t`. Do not `rm` the log to "reset" a soak. The reset marker is an epoch. Records older than that epoch are ignored.

---

## /etc/audit/auditd.conf

**What it holds.** How `auditd` rotates the log and what it does when the disk fills.

| Setting | Role |
|---------|------|
| `max_log_file` | Size in megabytes before rotation |
| `num_logs` | How many rotated files to keep |
| `max_log_file_action` | Usually `ROTATE` |
| `space_left_action` | What to do when free space crosses the first warning |
| `admin_space_left_action` | What to do when free space is lower still. The stock action is `SUSPEND` |
| `disk_full_action` | What to do when the disk is full. The stock action is `SUSPEND` |
| `disk_error_action` | What to do when a write fails |

**Which command writes it.** An editor, then a restart of `auditd`. No lab command writes it.

**Why it matters for soak.** Soak decides from AVC lines. If rotation deletes the file that held a denial, `ausearch` cannot see it. If `auditd` suspends because the disk is full, new denials are not written, and a monitor that only counts lines can look clean. Fail-closed applies when `ausearch` itself errors. It does not invent lines that `auditd` never wrote. Look at this file before a long soak.

**Look safely.** `cat /etc/audit/auditd.conf`. Confirm the stock actions on the host with the command in [LIVE_CHECKS.md](../LIVE_CHECKS.md).

---

## /usr/share/selinux/devel

**What it holds.** `Makefile` compiles a module. `include/` is the header tree (`make` reads it for interfaces such as `init_daemon_domain`). The package is `selinux-policy-devel`.

**Which command writes it.** The RPM. You run `make -f /usr/share/selinux/devel/Makefile name.pp` in a directory that contains `name.te` and `name.fc`.

**Look safely.** `ls /usr/share/selinux/devel/Makefile /usr/share/selinux/devel/include`.

---

## /usr/share/selinux/packages

**What it holds.** The `.pp` files from the policy RPMs, before they are copied into the module store at priority 200. A shopapi RPM installs its module from the package payload. It does not leave a second copy you then `semodule -i` by hand.

**Which command writes it.** The RPM.

**Look safely.** `ls /usr/share/selinux/packages`. The exact filenames are a live check.

---

## semanage export

**What it holds.** A transcript of local customizations: file contexts, ports, booleans, permissive domains. It is not a file until you redirect it.

**Which command writes it.** `semanage export` prints. `semanage import` would apply a transcript. The labs do not import.

**Look safely.** `sudo semanage export`. Read it. Do not pipe it back into `semanage import` on a host you have not backed up.

Next: [104 — a module built by hand](104-HAND-BUILT-MODULE.md).
