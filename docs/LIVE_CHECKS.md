# Live checks

These commands need rhel-qa. They are not part of the on-screen demo. [102](training/102-COMMANDS.md) names each one. Paste the output here after a run. Nothing below was captured in this repo.

## Command catalog

```bash
getenforce
sestatus
ls -Z /opt/shopapi/bin/shopapi
ls -dZ /opt/shopapi /var/log/shopapi /var/lib/shopapi
ps -eZ | grep shopapi
id -Z
matchpathcon /opt/shopapi/bin/shopapi /opt/shopapi/shopapi.jar /var/lib/shopapi /var/log/shopapi
matchpathcon /run/shopapi/no-such-file
sudo restorecon -Rvn /opt/shopapi /var/lib/shopapi /var/log/shopapi /run/shopapi
sudo semanage fcontext -l -C
sudo semanage port -l | grep -E '8091|8090'
sudo getsebool -a | head
sudo semanage boolean -l | head
sudo semanage permissive -l
sudo semodule -l | grep shopapi
sudo semodule --list-modules=full | head
seinfo -t shopapi_t -x
seinfo --permissive
sesearch -A -s shopapi_t -t shopapi_log_t -c file -p write
sesearch --dontaudit -s shopapi_t | head
sudo ausearch -m avc -ts recent --subject shopapi_t
sudo aureport -a
sudo aureport -a --summary
```

`ausearch -ts` with one argument `MM/DD/YYYY HH:MM:SS` prints `Invalid start time`. The date and the time are two arguments. Do not pass an epoch to `-ts`.

## Config files

```bash
cat /etc/selinux/config
ls -l /etc/selinux/targeted/policy/policy.33
ls /var/lib/selinux/targeted/active/
ls -l /etc/selinux/targeted/contexts/files/
sha256sum /etc/selinux/targeted/policy/policy.33 /var/lib/selinux/targeted/active/policy.kern
sudo ls /var/lib/selinux/targeted/active/modules
sudo ls /var/lib/selinux/targeted/active/file_contexts /var/lib/selinux/targeted/active/file_contexts.local
cat /sys/fs/selinux/enforce
grep -E 'max_log_file|num_logs|space_left_action|admin_space_left_action|disk_full_action|disk_error_action' /etc/audit/auditd.conf
ls /usr/share/selinux/devel/Makefile /usr/share/selinux/packages
sudo semanage export
```

## Process label

The unit has no `SELinuxContext` line. The java process type is `shopapi_t`.

```bash
systemctl cat shopapi.service | grep SELinuxContext || echo 'no SELinuxContext'
ps -o label,args -C java
```

`matchpathcon /opt/shopapi/bin/shopapi` prints `shopapi_exec_t`. `matchpathcon /opt/shopapi/shopapi.jar` prints `shopapi_lib_t`.

## Runtime path that is not on disk

`matchpathcon` answers for a path that does not exist. After the module is loaded this prints `shopapi_var_run_t`:

```bash
matchpathcon /run/shopapi/no-such-file
```

## Copy keeps the new label, move keeps the old one

`from-cp` wears the type of `/var/log/shopapi`. `from-mv` is still `etc_t`.

```bash
echo x > /tmp/label-src
sudo chcon -t etc_t /tmp/label-src
sudo cp /tmp/label-src /var/log/shopapi/from-cp
sudo mv /tmp/label-src /var/log/shopapi/from-mv
ls -Z /var/log/shopapi/from-cp /var/log/shopapi/from-mv
```

`matchpathcon /var/lib/shopapi` prints `shopapi_var_lib_t`. `matchpathcon /var/log/shopapi` prints `shopapi_log_t`.

## One AVC until the cache is flushed

With `shopapi_t` permissive, two curls of `/log` produce one ausearch line. `semodule -R` flushes the cache, and one more curl logs the denial again. `-ts recent` is a keyword, not a formatted date.

```bash
curl -sf http://127.0.0.1:8091/log
curl -sf http://127.0.0.1:8091/log
sudo ausearch -m avc -ts recent --subject shopapi_t
sudo semodule -R
curl -sf http://127.0.0.1:8091/log
sudo ausearch -m avc -ts recent --subject shopapi_t
```
