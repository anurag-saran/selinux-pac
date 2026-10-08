# shopapi — Spring Boot demo reference

This is the **demo** JVM. Offline `make check` uses deterministic goldens (`selinux/myapp.te`), not a live app.

Policy starts as a **types-only** seed in `selinux/shopapi/`. The allow list is generated on rhel-qa from **observed** AVCs (`dev_generate_policy.sh --app-name shopapi`). Do not paste a JVM permission list; if `execmem` does not appear in the AVC log, do not add it.

systemd starts a **private JRE launcher** at `/opt/shopapi/bin/java` (labeled `shopapi_exec_t`) plus **`SELinuxContext=`**. `/usr/bin/java` is shared `java_exec_t` and cannot be the entrypoint under enforcing `shopapi_t`.

Paths and port: `config/shopapi.manifest.yml` → `/etc/shopapi.env` (bootstrap writes that file).
