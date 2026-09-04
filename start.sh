#!/bin/bash

set -eu

echo "==> Starting Tymeslot"

# --- Operator configuration file --------------------------------------------
# /app/data/.env lets an operator manage variables in a file instead of one
# `cloudron env set` per key. On first boot it is seeded from the packaged
# .env.example with every assignment commented out, so a fresh install starts
# with the documented list in place and nothing enabled by it.
#
# Values are applied as a fallback: anything already in the environment (i.e.
# set through Cloudron) wins, which is the precedence config/runtime.exs
# applies via Tymeslot.Infrastructure.DotenvLoader. Loading the file here,
# before the key generation below, is what makes SECRET_KEY_BASE and
# DATA_ENCRYPTION_KEY settable from it at all.
#
# The file is parsed, never sourced: sourcing would run whatever an operator
# pasted into it, and would let it override Cloudron's own variables.
ENV_FILE="/app/data/.env"
ENV_TEMPLATE="/app/.env.example"

if [ ! -f "$ENV_FILE" ] && [ -f "$ENV_TEMPLATE" ]; then
  {
    cat <<'HEADER'
# Tymeslot configuration
#
# Created on first boot from the packaged .env.example with every value
# commented out, so it changes nothing until you edit it. Uncomment the
# lines you need, then restart the app:
#
#   cloudron restart --app <your-app-domain>
#
# Variables set with `cloudron env set`, or on the dashboard's Environment
# tab, always win over the values below; use those for one-off overrides.
#
# Cloudron provides the database, the mail relay and OIDC through addons, so
# leave the DATABASE_*, POSTGRES_* and SMTP_* entries commented out unless
# you deliberately point Tymeslot at your own servers. The same goes for
# EMAIL_ADAPTER: uncommenting it as "test" silently discards every email.
#
# SECRET_KEY_BASE and DATA_ENCRYPTION_KEY are generated on first boot and
# kept in /app/data, so leave them alone unless you are restoring an
# existing installation. Changing DATA_ENCRYPTION_KEY on an install that
# already holds encrypted credentials makes them undecryptable.
#
# Upgrades never touch this file. The packaged reference copy at
# /app/.env.example is refreshed with each release.

HEADER
    sed 's/^\([A-Za-z_][A-Za-z0-9_]*=\)/# \1/' "$ENV_TEMPLATE"
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "==> Seeded $ENV_FILE from the packaged template (nothing enabled)"
fi

# Applies KEY=value lines that name a variable which is not already set.
# Unterminated quotes (a multi-line value) are skipped rather than guessed at;
# DotenvLoader parses those correctly when the release boots.
load_env_file() {
  local file="$1"
  local line key value

  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      '' | '#'*) continue ;;
      export\ *) line="${line#export }" ;;
    esac
    case "$line" in
      *=*) ;;
      *) continue ;;
    esac

    key="${line%%=*}"
    key="${key%"${key##*[![:space:]]}"}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
      \"* | \'*) continue ;;
      *)
        value="${value%%[[:space:]]#*}"
        value="${value%"${value##*[![:space:]]}"}"
        ;;
    esac

    if [ -z "${!key+set}" ]; then
      export "$key=$value"
      loaded_keys="${loaded_keys} ${key}"
    fi
  done < "$file"

  return 0
}

loaded_keys=""
load_env_file "$ENV_FILE"
if [ -n "$loaded_keys" ]; then
  echo "==> Loaded from $ENV_FILE:$loaded_keys"
else
  echo "==> No variables applied from $ENV_FILE"
fi

# Generate SECRET_KEY_BASE on first run if not already set via env
SECRET_FILE="/app/data/secret_key_base"
if [ -z "${SECRET_KEY_BASE:-}" ]; then
  if [ ! -f "$SECRET_FILE" ]; then
    openssl rand -base64 64 | tr -d '\n' > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
    echo "==> Generated SECRET_KEY_BASE (first run)"
  fi
  export SECRET_KEY_BASE=$(cat "$SECRET_FILE")
  echo "==> SECRET_KEY_BASE loaded from $SECRET_FILE"
else
  echo "==> SECRET_KEY_BASE set via environment"
fi

# Generate DATA_ENCRYPTION_KEY on first run if not already set via env.
# This encrypts credentials at rest independently of SECRET_KEY_BASE, so the
# session secret can be rotated without making stored credentials undecryptable.
# It MUST persist across restarts — losing it makes existing credentials
# unrecoverable, forcing every integration to be reconnected.
DATA_KEY_FILE="/app/data/data_encryption_key"
if [ -z "${DATA_ENCRYPTION_KEY:-}" ]; then
  if [ ! -f "$DATA_KEY_FILE" ]; then
    openssl rand -base64 48 | tr -d '\n' > "$DATA_KEY_FILE"
    chmod 600 "$DATA_KEY_FILE"
    echo "==> Generated DATA_ENCRYPTION_KEY (first run)"
  fi
  export DATA_ENCRYPTION_KEY=$(cat "$DATA_KEY_FILE")
  echo "==> DATA_ENCRYPTION_KEY loaded from $DATA_KEY_FILE"

  # This script's `export` is local to this process tree and invisible to a
  # later `cloudron exec`/`eval` session, but config/runtime.exs also loads
  # /app/data/.env (see DotenvLoader) — persist the key there so exec sessions
  # (e.g. the re-encryption sweep) see it too. Upsert rather than append so
  # restarts don't duplicate the line.
  if [ ! -f "$ENV_FILE" ]; then
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE"
  fi
  if grep -q '^DATA_ENCRYPTION_KEY=' "$ENV_FILE"; then
    sed -i "s|^DATA_ENCRYPTION_KEY=.*|DATA_ENCRYPTION_KEY=${DATA_ENCRYPTION_KEY}|" "$ENV_FILE"
  else
    echo "DATA_ENCRYPTION_KEY=${DATA_ENCRYPTION_KEY}" >> "$ENV_FILE"
  fi
else
  echo "==> DATA_ENCRYPTION_KEY set via environment"
fi

# Create necessary directories for runtime
mkdir -p /app/data/tzdata /app/data/uploads
chown -R cloudron:cloudron /app/data
chmod -R 700 /app/data
echo "Created runtime directories:"
ls -la /app/data/

# Log environment (without sensitive data)
echo "Environment configured:"
echo "  MIX_ENV: ${MIX_ENV:-not set}"
echo "  PHX_HOST: ${PHX_HOST:-not set}"
echo "  PORT: ${PORT:-not set}"
echo "  DEPLOYMENT_TYPE: ${DEPLOYMENT_TYPE:-not set}"
echo ""
echo "  Note: Calendar and video integrations are managed through the dashboard"

# Log Cloudron addon detection (only on Cloudron deployments)
if [ "${DEPLOYMENT_TYPE:-}" = "cloudron" ] || [ "${DEPLOYMENT_TYPE:-}" = "main" ]; then
  if [ -n "${CLOUDRON_MAIL_SMTP_SERVER:-}" ]; then
    echo "==> Cloudron sendmail addon detected (relay: ${CLOUDRON_MAIL_SMTP_SERVER})"
  else
    echo "==> Cloudron sendmail addon not detected, using EMAIL_ADAPTER=${EMAIL_ADAPTER:-smtp}"
  fi

  if [ -n "${CLOUDRON_OIDC_CLIENT_ID:-}" ]; then
    echo "==> Cloudron OIDC addon detected (issuer: ${CLOUDRON_OIDC_ISSUER:-unknown})"
  else
    echo "==> Cloudron OIDC addon not detected"
  fi
fi

# Run database migrations
echo "Running database migrations..."
/app/bin/tymeslot eval 'Ecto.Migrator.with_repo(Tymeslot.Repo, &Ecto.Migrator.run(&1, :up, all: true))'

# Start the Phoenix server
echo "Starting Phoenix server..."
/app/bin/tymeslot start
