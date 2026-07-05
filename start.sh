#!/bin/bash

set -eu

echo "==> Starting Tymeslot"

# Environment variables are set externally in production

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
ENV_FILE="/app/data/.env"
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
  touch "$ENV_FILE"
  chmod 600 "$ENV_FILE"
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
