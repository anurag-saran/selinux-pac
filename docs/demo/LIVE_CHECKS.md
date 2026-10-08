# Live checks

These commands need rhel-qa with the shopapi module loaded. They are not part of the on-screen demo.

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
