#!/bin/sh
# Railway shim for erseco/alpine-moodle.
#
# Runs as root so it can repair the ownership of Railway's volume mount, then
# hands over to the stock entrypoint as uid 65534, which is the user the image
# normally runs as (php-fpm's pool has no `user` directive, so it cannot run as
# root, and nginx/runit are configured for nobody throughout).
set -eu

log() { echo "[railway] $*"; }

MOODLE_UID=65534
MOODLE_GID=65534
WWW_ROOT=/var/www

# --- 1. Refuse to boot without a real admin password -------------------------
# The base image ships MOODLE_PASSWORD=PLEASE_CHANGEME and installs the site
# with it, so an unset value is a published admin account with a password
# printed in upstream's README.
case "${MOODLE_PASSWORD:-}" in
    ""|PLEASE_CHANGEME)
        echo "[railway] FATAL: MOODLE_PASSWORD is empty or still the upstream default." >&2
        echo "[railway] Set MOODLE_PASSWORD to a private value and redeploy." >&2
        exit 1
        ;;
esac

# --- 2. Site URL -------------------------------------------------------------
# Moodle bakes wwwroot into config.php and rejects requests whose host does not
# match it, so the deploy's own domain has to be discovered at boot.
if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
    case "${SITE_URL:-}" in
        ""|http://localhost|https://localhost|*example.com*)
            SITE_URL="https://${RAILWAY_PUBLIC_DOMAIN}"
            export SITE_URL
            log "SITE_URL derived from RAILWAY_PUBLIC_DOMAIN: $SITE_URL"
            ;;
    esac
fi

# Moodle refuses to boot ("Must use https address in wwwroot when ssl proxy
# enabled!") if sslproxy is on while wwwroot is http, so follow the scheme that
# was actually resolved rather than assuming TLS.
case "${SITE_URL:-}" in
    https://*) SSLPROXY=true ;;
    *)         SSLPROXY=false ;;
esac
export SSLPROXY
log "SSLPROXY=$SSLPROXY for $SITE_URL"

# --- 3. Volume ownership -----------------------------------------------------
# Railway mounts volumes owned by uid 0. The image runs as uid 65534, and Moodle
# writes both its code tree (/var/www/html, kept on the volume so admin-installed
# plugins survive a redeploy) and its data root (/var/www/moodledata).
mkdir -p "$WWW_ROOT/html" "$WWW_ROOT/moodledata"
owner=$(stat -c %u:%g "$WWW_ROOT" 2>/dev/null || echo unknown)
log "mount $WWW_ROOT owned by $owner"
if [ "$owner" != "${MOODLE_UID}:${MOODLE_GID}" ]; then
    log "repairing ownership of $WWW_ROOT to ${MOODLE_UID}:${MOODLE_GID}"
    chown -R "${MOODLE_UID}:${MOODLE_GID}" "$WWW_ROOT"
else
    log "ownership already correct, skipping chown"
fi
chmod 0755 "$WWW_ROOT"

# --- 4. PHP sizing -----------------------------------------------------------
# opcache: the base image enables the extension and leaves every limit at its
# default. Moodle 5.2 is ~50,000 PHP files against a default
# opcache.max_accelerated_files of 10,000 and 128 MB of cache, so the cache
# thrashes permanently and every request recompiles.
cat > /etc/php83/conf.d/99-railway.ini <<'INI'
; Railway tuning — sized for Moodle's file count, not PHP's defaults.
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=256
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=60000
opcache.revalidate_freq=60
opcache.save_comments=1
realpath_cache_size=4096k
realpath_cache_ttl=600
INI
chown "${MOODLE_UID}:${MOODLE_GID}" /etc/php83/conf.d/99-railway.ini

# php-fpm: the base pool is a fixed pm.max_children = 100 against a 256 MB
# memory_limit, i.e. an OOM kill on any small plan. Size it from the cgroup.
mem_max=""
if [ -r /sys/fs/cgroup/memory.max ]; then
    mem_max=$(cat /sys/fs/cgroup/memory.max)
elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    mem_max=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
fi
case "$mem_max" in
    ''|max|*[!0-9]*) mem_mb=2048 ;;
    *) mem_mb=$((mem_max / 1024 / 1024)) ;;
esac
[ "$mem_mb" -gt 32768 ] && mem_mb=2048   # unconstrained cgroup reports the host
# Reserve ~40% for opcache, nginx, cron and the page cache; budget 96 MB/worker.
children=$(( (mem_mb * 60 / 100) / 96 ))
[ "$children" -lt 4 ] && children=4
[ "$children" -gt 100 ] && children=100
sed -i "s/^pm.max_children *=.*/pm.max_children = ${children}/" /etc/php83/php-fpm.d/www.conf
log "cgroup memory ${mem_mb}MB -> pm.max_children = ${children}"

# nginx and php-fpm log to /dev/stdout, which resolves to PID 1's pipe. This shim
# starts as root, so that pipe is root-owned and the dropped-privilege processes
# cannot open it (nginx: [emerg] open() "/dev/stdout" failed (13: Permission denied)).
# Widen it before dropping.
chmod 0666 /proc/self/fd/1 /proc/self/fd/2 2>/dev/null || log "could not widen stdout/stderr"

exec su-exec "${MOODLE_UID}:${MOODLE_GID}" /bin/docker-entrypoint.sh "$@"
