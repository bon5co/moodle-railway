# Moodle 5.2.2 packaged for Railway.
#
# Base image: erseco/alpine-moodle (nginx + php-fpm 8.3 + runit, Moodle core baked
# at /usr/src/moodle and synced into the web root on boot with third-party plugins
# preserved). Everything added here is Railway-specific:
#
#   * repairs the ownership of Railway's uid-0 volume mount before dropping to nobody
#   * honours the injected $PORT (the base image bakes `listen 8080`)
#   * refuses to boot without an admin password instead of shipping a known default
#   * tunes opcache for a 50,013-file application and sizes php-fpm from the cgroup
#   * bakes every literal so the published template has no blank required variables
FROM erseco/alpine-moodle:v5.2.2

USER root

# su-exec: BusyBox setpriv has no --reuid, so it cannot drop privileges here.
RUN apk add --no-cache su-exec

# Honour Railway's injected $PORT. The base image bakes `listen 8080` and its
# entrypoint runs envsubst over nginx.conf, so turning the literal into a
# placeholder is enough for the port to follow the platform.
RUN sed -i 's/listen 8080 default_server;/listen ${PORT} default_server;/' /etc/nginx/nginx.conf

# A healthcheck endpoint nginx answers itself. Railway's default healthcheck window is
# 300s and templateGenerate does not carry healthcheckTimeout into a published template,
# so the probe has to be something that answers as soon as nginx binds -- not a Moodle
# page, which is only served once the install has finished. Railway also rejects a
# healthcheckPath containing a file extension, which rules out /login/index.php.
RUN sed -i 's|^\(\s*\)server_name _;|\1server_name _;\n\1location = /healthz { access_log off; add_header Content-Type text/plain; return 200 "ok"; }|' /etc/nginx/nginx.conf \
 && grep -q 'location = /healthz' /etc/nginx/nginx.conf

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh \
 && chown -R nobody:nobody /etc/nginx /etc/php83 /docker-entrypoint-init.d

# Defaults that are literals: baked here because templateGenerate drops the
# defaultValue of any template variable whose value is not a Railway expression,
# which would publish them as blank required fields on the deploy form.
ENV PORT=8080 \
    MOODLE_USERNAME=admin \
    MOODLE_EMAIL=admin@example.com \
    MOODLE_SITENAME=Moodle \
    MOODLE_LANGUAGE=en \
    MOODLE_PASSWORD="" \
    DB_TYPE=pgsql \
    DB_PREFIX=mdl_ \
    DB_PORT=5432 \
    DB_NAME=postgres \
    DB_USER=postgres \
    REVERSEPROXY=true \
    SSLPROXY=true \
    REAL_IP_HEADER=X-Forwarded-For \
    REAL_IP_RECURSIVE=on \
    REAL_IP_FROM="0.0.0.0/0,::/0" \
    AUTO_UPDATE_MOODLE=true \
    SYNC_MOODLE_CODE=auto \
    SYNC_PRESERVE_PLUGINS=true \
    RUN_CRON_TASKS=true \
    max_input_vars=5000 \
    memory_limit=256M \
    upload_max_filesize=256M \
    post_max_size=256M \
    client_max_body_size=256M \
    max_execution_time=0

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
