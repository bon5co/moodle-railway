# moodle-railway

Wrapper image for deploying [Moodle](https://moodle.org) 5.2.2 on
[Railway](https://railway.com), built on `erseco/alpine-moodle` (nginx + php-fpm 8.3 +
Moodle cron, all supervised by runit in one container).

The upstream image is already a good single-container Moodle. What it is not is a
*Railway* Moodle. This wrapper adds the platform-specific work that every Moodle
listing on the Railway marketplace is currently missing.

## What this image changes

1. **Honours Railway's injected `$PORT`.** The base image bakes `listen 8080` into
   `nginx.conf`; the wrapper turns that into a `${PORT}` placeholder, which the base
   entrypoint's own `envsubst` pass then fills in. A public Railway service must honour
   the injected port, because the platform's HTTP healthcheck dials it rather than the
   domain's target port.
2. **Repairs the volume's ownership before dropping privileges.** Railway mounts volumes
   owned by uid 0, and Moodle's nginx/php-fpm pool runs unprivileged. The entrypoint
   starts as root, `chown`s `/var/www` when (and only when) the owner is wrong, and then
   hands over to the stock entrypoint via `su-exec` as uid 65534. BusyBox's `setpriv` has
   no `--reuid`, so `su-exec` is installed for this.
3. **Keeps the webroot on the volume, so admin-installed plugins survive a redeploy.**
   `/var/www` (both `html/` and `moodledata/`) is the mount, and the base image's
   `SYNC_PRESERVE_PLUGINS=true` keeps third-party plugin directories through a code sync.
4. **Sizes opcache for Moodle's actual file count.** Moodle 5.2 ships 50,013 PHP files
   against PHP's default `opcache.max_accelerated_files=10000` and
   `opcache.memory_consumption=128`. The wrapper writes 60000 / 256 MB plus a larger
   realpath cache.
5. **Sizes `pm.max_children` from the container's cgroup memory limit** rather than the
   fixed 100 the base image ships, which would let php-fpm oversubscribe a small plan.
6. **Derives `SITE_URL` from `RAILWAY_PUBLIC_DOMAIN`,** and sets `SSLPROXY` from that
   URL's scheme. Moodle raises `Must use https address in wwwroot when ssl proxy enabled!`
   if the two disagree, which is a hard 500 on every page.
7. **Sets `real_ip` from `X-Forwarded-For`,** so Moodle logs and rate limits see the real
   client rather than Railway's edge address.
8. **Refuses to boot without an admin password,** including the base image's
   `PLEASE_CHANGEME` placeholder.
9. **Widens stdout/stderr before the privilege drop** — nginx and php-fpm write to
   `/dev/stdout`, which resolves to PID 1's root-owned pipe and is otherwise unopenable
   after the drop (`nginx: [emerg] open() "/dev/stdout" failed (13: Permission denied)`).

## Environment

| Variable | Notes |
| --- | --- |
| `MOODLE_PASSWORD` | Required. The container exits 1 if it is empty or `PLEASE_CHANGEME`. Re-applied on every boot, so a redeploy is a working password reset. |
| `MOODLE_USERNAME`, `MOODLE_EMAIL`, `MOODLE_SITENAME`, `MOODLE_LANGUAGE` | Defaulted in the image. |
| `DB_TYPE`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASS`, `DB_PREFIX` | PostgreSQL by default. |
| `SITE_URL` | Derived from `RAILWAY_PUBLIC_DOMAIN` when unset or still pointing at localhost/example.com. |
| `PORT` | Injected by Railway. |

## Volume

Mount one volume at `/var/www`. It holds both the Moodle code tree (`html/`) and the
data directory (`moodledata/`).

10. **Serves `/healthz` from nginx,** so the service can carry a Railway healthcheck at
    all. Railway rejects a `healthcheckPath` containing a file extension, which rules out
    Moodle's own pages, and `templateGenerate` does not carry `healthcheckTimeout` into a
    published template.

### Reverse proxy

Railway terminates TLS at its edge and forwards the public `Host` header verbatim.
Moodle's `$CFG->reverseproxy` is for the different-internal-hostname case, and Moodle 5
raises `reverseproxyabused` (a 500 on every page) when it is set while the received Host
matches `wwwroot` — `lib/setuplib.php:753`. So this image forces `REVERSEPROXY=false` and
relies on `SSLPROXY`, which the entrypoint derives from the scheme of `SITE_URL`.
