#!/bin/bash
# export VAR="$(opt ...)" is used throughout: opt only reads options.json, which the
# Supervisor has already validated, so masking its exit status is harmless.
# shellcheck disable=SC2155
# SPL Equipment Booking (LibreBooking) add-on start-up.
#
# 1. Reads the add-on options (/data/options.json).
# 2. Gets the MariaDB add-on's service login from the Supervisor and creates this add-on's
#    own database and database user (IF NOT EXISTS; nothing is ever dropped).
# 3. Installs LibreBooking's schema into an empty database, or applies upgrades.
# 4. Keeps uploads under /data and config.php under the add-on config folder.
# 5. Starts the background jobs (reminders etc.) and hands over to the image's own
#    entrypoint, which configures and starts Apache.
#
# Paths and the Supervisor URL can be overridden with environment variables for local
# testing (see ../../../docker-compose.yml); in Home Assistant the defaults apply.
set -euo pipefail

OPTIONS_FILE="${SPL_OPTIONS_FILE:-/data/options.json}"
DATA_DIR="${SPL_DATA_DIR:-/data}"
CONFIG_DIR="${SPL_CONFIG_DIR:-/config}"
APP_DIR="${SPL_APP_DIR:-/var/www/html}"
SUPERVISOR_URL="${SPL_SUPERVISOR_URL:-http://supervisor}"
LB_DB_PHP="${SPL_LB_DB_PHP:-/opt/spl/lb-db.php}"
CRON_FILE="${SPL_CRON_FILE:-/opt/spl/lb-jobs-cron}"
RUN_AS="${SPL_RUN_AS:-www-data}"

log() { echo "[spl-booking] $*"; }
die() { echo "[spl-booking] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------- options
[ -f "$OPTIONS_FILE" ] || die "options file $OPTIONS_FILE not found"
opt() { jq -r --arg k "$1" 'if has($k) and .[$k] != null then .[$k] else empty end' "$OPTIONS_FILE"; }
opt_bool() { [ "$(opt "$1")" = "true" ] && echo true || echo false; }

PUBLIC_URL="$(opt public_url)"; PUBLIC_URL="${PUBLIC_URL%/}"
[ -n "$PUBLIC_URL" ] || die "set public_url in the add-on configuration"
ADMIN_EMAIL="$(opt admin_email)"
[ -n "$ADMIN_EMAIL" ] || die "set admin_email in the add-on configuration"
DB_NAME="$(opt database_name)"; DB_NAME="${DB_NAME:-librebooking}"
[[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || die "database_name may only contain letters, digits and _"
DB_APP_USER="${DB_NAME}"
# Optional: a login created in the MariaDB add-on's own configuration (Logins and Rights).
# When set, the add-on uses it as is and doesn't create a database user itself.
DB_LOGIN_USER="$(opt database_username)"
DB_LOGIN_PASSWORD="$(opt database_password)"
TIMEZONE="$(opt timezone)"; TIMEZONE="${TIMEZONE:-Australia/Sydney}"

mkdir -p "$DATA_DIR" "$CONFIG_DIR"

# A secret kept in /data, created once.
secret() {
  local file="$DATA_DIR/$1"
  if [ ! -s "$file" ]; then
    (umask 077; head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32 >"$file")
  fi
  cat "$file"
}
DB_APP_PASSWORD="$(secret db_password)"
if [ -n "$DB_LOGIN_USER" ]; then
  [ -n "$DB_LOGIN_PASSWORD" ] || die "database_username is set, so set database_password too"
  DB_APP_USER="$DB_LOGIN_USER"; DB_APP_PASSWORD="$DB_LOGIN_PASSWORD"
fi
INSTALL_PASSWORD="$(secret install_password)"

# ---------------------------------------------------------------- database login
if [ -n "${SPL_DB_HOST:-}" ]; then
  # Local testing: admin login given directly.
  DB_HOST="$SPL_DB_HOST"; DB_PORT="${SPL_DB_PORT:-3306}"
  DB_ADMIN_USER="${SPL_DB_ADMIN_USER:?}"; DB_ADMIN_PASSWORD="${SPL_DB_ADMIN_PASSWORD:?}"
else
  [ -n "${SUPERVISOR_TOKEN:-}" ] || die "no Supervisor token; is this running as a Home Assistant add-on?"
  log "Getting the MariaDB login from the Supervisor"
  svc="$(curl -fsS -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" "${SUPERVISOR_URL}/services/mysql")" \
    || die "the MariaDB add-on is not available. Install and start the official MariaDB add-on first."
  # (With database_username set, only the host and port from this are used.)
  DB_HOST="$(jq -r '.data.host' <<<"$svc")"; DB_PORT="$(jq -r '.data.port // 3306' <<<"$svc")"
  DB_ADMIN_USER="$(jq -r '.data.username' <<<"$svc")"; DB_ADMIN_PASSWORD="$(jq -r '.data.password' <<<"$svc")"
  [ -n "$DB_HOST" ] && [ "$DB_HOST" != null ] || die "the Supervisor returned no MariaDB host"
fi

# The MariaDB add-on allows its service login only from Home Assistant's internal IPv4
# network, but core-mariadb can resolve to IPv6 first. Use its IPv4 address for the admin
# login. (This add-on's own database user is allowed from any address.)
DB_ADMIN_HOST="$DB_HOST"
if ipv4="$(getent ahostsv4 "$DB_HOST" 2>/dev/null | awk 'NR==1 {print $1}')" && [ -n "$ipv4" ]; then
  DB_ADMIN_HOST="$ipv4"
fi

# --skip-ssl: the MariaDB 11.4+ client verifies the server's TLS certificate by default,
# and the MariaDB add-on has none it can verify. The connection stays on Home Assistant's
# internal Docker network.
if [ -n "$DB_LOGIN_USER" ]; then
  DB_ADMIN_USER="$DB_LOGIN_USER"; DB_ADMIN_PASSWORD="$DB_LOGIN_PASSWORD"
fi
admin_sql() {
  MYSQL_PWD="$DB_ADMIN_PASSWORD" mariadb --protocol=TCP --skip-ssl -h "$DB_ADMIN_HOST" -P "$DB_PORT" \
    -u "$DB_ADMIN_USER" --batch --skip-column-names "$@"
}

log "Waiting for MariaDB at ${DB_HOST} (${DB_ADMIN_HOST}):${DB_PORT} (user ${DB_ADMIN_USER})"
for i in $(seq 1 60); do
  if err="$(admin_sql -e 'SELECT 1' 2>&1 >/dev/null)"; then break; fi
  [ "$i" -eq 1 ] || [ $((i % 15)) -eq 0 ] && log "MariaDB not ready yet: ${err}"
  [ "$i" -eq 60 ] && die "cannot log in to MariaDB at ${DB_HOST}:${DB_PORT}: ${err}"
  sleep 2
done

if [ -n "$DB_LOGIN_USER" ]; then
  log "Using the MariaDB login '${DB_APP_USER}' from the add-on options"
  admin_sql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci" \
    || die "login '${DB_APP_USER}' cannot use database '${DB_NAME}'. In the MariaDB add-on add '${DB_NAME}' under Databases and give '${DB_APP_USER}' rights on it."
else
log "Ensuring database '${DB_NAME}' and user '${DB_APP_USER}' exist"
pw_sql="${DB_APP_PASSWORD//\'/\'\'}"
admin_sql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_APP_USER}'@'%' IDENTIFIED BY '${pw_sql}';
ALTER USER '${DB_APP_USER}'@'%' IDENTIFIED BY '${pw_sql}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_APP_USER}'@'%';
FLUSH PRIVILEGES;
SQL
fi

# ---------------------------------------------------------------- LibreBooking settings
# LibreBooking reads any setting from LB_<KEY> environment variables, which take
# precedence over config.php (https://librebooking.readthedocs.io, Basic Configuration).
export LB_DATABASE_HOSTSPEC="${DB_HOST}"
[ "$DB_PORT" = "3306" ] || LB_DATABASE_HOSTSPEC="${DB_HOST}:${DB_PORT}"
export LB_DATABASE_NAME="$DB_NAME" LB_DATABASE_USER="$DB_APP_USER" LB_DATABASE_PASSWORD="$DB_APP_PASSWORD"
export LB_INSTALL_PASSWORD="$INSTALL_PASSWORD"
export LB_DEFAULT_TIMEZONE="$TIMEZONE"
export LB_SCRIPT_URL="${PUBLIC_URL}/Web"
export LB_ADMIN_EMAIL="$ADMIN_EMAIL"
export LB_APP_TITLE="$(opt app_title)"
export LB_COMPANY_NAME="$(opt company_name)"
export LB_COMPANY_URL="$(opt company_url)"
export LB_LOGGING_LEVEL="$(opt log_level)"

# Who can see and book
export LB_REGISTRATION_ALLOW_SELF_REGISTRATION="$(opt_bool allow_self_registration)"
export LB_AUTHENTICATION_REQUIRED_EMAIL_DOMAINS="$(opt allowed_email_domains)"
export LB_PRIVACY_VIEW_SCHEDULES="$(opt_bool public_schedule)"
export LB_PRIVACY_VIEW_RESERVATIONS="$(opt_bool public_booking_details)"
export LB_PRIVACY_HIDE_USER_DETAILS="$(opt_bool hide_user_details)"
export LB_PRIVACY_PUBLIC_FUTURE_DAYS="$(opt public_days)"
export LB_ICS_FUTURE_DAYS="$(opt public_days)"

# Approvals: email the admins when a booking needs approving
if [ "$(opt_bool notify_admins_of_approvals)" = true ]; then
  export LB_RESERVATION_NOTIFY_APPLICATION_ADMIN_APPROVAL=true
  export LB_RESERVATION_NOTIFY_GROUP_ADMIN_APPROVAL=true
  export LB_RESERVATION_NOTIFY_RESOURCE_ADMIN_APPROVAL=true
fi

# Email
SMTP_HOST="$(opt smtp_host)"
if [ -n "$SMTP_HOST" ]; then
  export LB_EMAIL_ENABLED=true LB_PHPMAILER_MAILER=smtp
  export LB_PHPMAILER_SMTP_HOST="$SMTP_HOST" LB_PHPMAILER_SMTP_PORT="$(opt smtp_port)"
  secure="$(opt smtp_security)"; [ "$secure" = none ] && secure=""
  export LB_PHPMAILER_SMTP_SECURE="$secure"
  export LB_PHPMAILER_SMTP_USERNAME="$(opt smtp_username)" LB_PHPMAILER_SMTP_PASSWORD="$(opt smtp_password)"
  if [ -n "$LB_PHPMAILER_SMTP_USERNAME" ]; then export LB_PHPMAILER_SMTP_AUTH=true; else export LB_PHPMAILER_SMTP_AUTH=false; fi
  from="$(opt email_from)"; export LB_EMAIL_DEFAULT_FROM_ADDRESS="${from:-$ADMIN_EMAIL}"
  export LB_EMAIL_DEFAULT_FROM_NAME="${LB_APP_TITLE}" LB_ADMIN_EMAIL_NAME="${LB_APP_TITLE}"
else
  export LB_EMAIL_ENABLED=false
fi

# Embedding in other sites (the wiki): allow only the listed sites to frame the pages.
embed="$(jq -r '(.embed_allowed_from // []) | map(select(. != "")) | join(" ")' "$OPTIONS_FILE")"
if [ -n "$embed" ]; then
  export LB_SECURITY_HEADERS=true
  export LB_SECURITY_CONTENT_SECURITY_POLICY="frame-ancestors 'self' ${embed}"
  export LB_SECURITY_X_FRAME=sameorigin  # browsers use frame-ancestors instead when both are set
else
  export LB_SECURITY_HEADERS=false
fi

# Advanced: any other setting, as KEY=value lines (e.g. LB_SCHEDULE_SHOW_WEEK_NUMBERS=true)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  key="${line%%=*}"
  [[ "$key" =~ ^LB_[A-Z0-9_]+$ ]] || { log "ignoring extra setting '$key' (must look like LB_SOME_KEY)"; continue; }
  case "$key" in
    LB_DATABASE_*|LB_INSTALL_PASSWORD) log "ignoring extra setting $key (managed by the add-on)"; continue ;;
  esac
  export "$key=${line#*=}"
done < <(jq -r '(.extra_settings // [])[]' "$OPTIONS_FILE")

# ---------------------------------------------------------------- config.php and uploads
# The image's entrypoint keeps config.php in /config; here /config is the add-on config
# folder (addon_configs/<slug> on the host), so it survives updates and is backed up.
if [ ! -f "$CONFIG_DIR/config.php" ]; then
  log "Creating config.php in the add-on config folder"
  cp "$APP_DIR/config/config.dist.php" "$CONFIG_DIR/config.php"
fi
ln -sf "$CONFIG_DIR/config.php" "$APP_DIR/config/config.php"
chown "$RUN_AS" "$CONFIG_DIR/config.php" 2>/dev/null || true

for dir in images reservation; do
  target="$DATA_DIR/uploads/$dir"
  link="$APP_DIR/Web/uploads/$dir"
  if [ ! -d "$target" ]; then
    mkdir -p "$target"
    [ -d "$link" ] && [ ! -L "$link" ] && cp -a "$link/." "$target/"
  fi
  rm -rf "$link"
  ln -s "$target" "$link"
  chown -R "$RUN_AS" "$target" 2>/dev/null || true
done

# Logs written by both Apache (as www-data) and the jobs: create them owned by www-data.
LB_LOGGING_FOLDER="${LB_LOGGING_FOLDER:-/var/log/librebooking}"; export LB_LOGGING_FOLDER
mkdir -p "$LB_LOGGING_FOLDER"
touch "$LB_LOGGING_FOLDER/app.log" "$LB_LOGGING_FOLDER/sql.log"
chown -R "$RUN_AS" "$LB_LOGGING_FOLDER" 2>/dev/null || true

# ---------------------------------------------------------------- install or upgrade
status="$(php "$LB_DB_PHP" status "$APP_DIR")" || die "cannot read the database state"
case "$status" in
  empty)
    log "Empty database: installing LibreBooking"
    php "$LB_DB_PHP" install "$APP_DIR" || die "installation failed (see above)"
    log "Installed. Open ${PUBLIC_URL}/Web/register.php and register with ${ADMIN_EMAIL} to become the administrator."
    ;;
  installed*)
    php "$LB_DB_PHP" upgrade "$APP_DIR" || die "database upgrade failed (see above); your data has not been changed by this add-on"
    ;;
  foreign*)
    die "database '${DB_NAME}' already holds tables that are not a LibreBooking installation. Choose another database_name."
    ;;
  *) die "unexpected database state: $status" ;;
esac

# ---------------------------------------------------------------- background jobs
# Reminders, auto-release, waitlist and session clean-up (LibreBooking's lb-jobs-cron).
if [ "${SPL_NO_CRON:-}" != 1 ]; then
  log "Starting background jobs"
  runuser -u "$RUN_AS" --preserve-environment -- supercronic -quiet "$CRON_FILE" &
fi

# ---------------------------------------------------------------- remaining set-up
# What the image's own entrypoint.sh would do, minus writing the database and install
# passwords into config.php and echoing them (it runs with set -x). The passwords stay in
# the environment only, which LibreBooking reads before config.php.

# Plugin configuration files, kept in the add-on config folder
while IFS= read -r -d '' source; do
  target="${source//.dist/}"
  [ -f "$CONFIG_DIR/$(basename "$target")" ] || cp "$source" "$CONFIG_DIR/$(basename "$target")"
  [ -e "$target" ] || ln -s "$CONFIG_DIR/$(basename "$target")" "$target"
done < <(find "$APP_DIR/plugins" -type f -name "*dist*" -print0)

# PHP's timezone
if [ -f "/usr/share/zoneinfo/${TIMEZONE}" ] && [ -d /usr/local/etc/php/conf.d ]; then
  printf '[Date]\ndate.timezone="%s"\n' "$TIMEZONE" >/usr/local/etc/php/conf.d/zz-spl-timezone.ini
fi

# LibreBooking's own logs into the add-on log
tail -n 0 -F "$LB_LOGGING_FOLDER/app.log" "$LB_LOGGING_FOLDER/sql.log" 2>/dev/null &

log "Starting LibreBooking at ${PUBLIC_URL}"
if [ $# -gt 0 ]; then exec "$@"; fi
exec apache2-foreground
