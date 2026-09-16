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
ENV_TEMPLATE_SCRIPT="/app/env-template.sh"
seeded_now=0

# An install upgrading from a release that generated DATA_ENCRYPTION_KEY already
# has an .env holding that one line, so "the file exists" is not the same as
# "the operator has a file". Treat one the container wrote entirely by itself as
# unseeded, and carry its key line into the seeded version.
env_file_is_machine_written() {
  local file="$1"
  local line

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      '' | '#'* | DATA_ENCRYPTION_KEY=*) continue ;;
      *) return 1 ;;
    esac
  done < "$file"

  return 0
}

# Seeding happens once. The marker is what makes that true: without it the
# seeded file, being comments plus the container's own key line, would look
# machine-written on every subsequent boot and be rewritten each time.
env_file_is_seeded() {
  grep -q '^# tymeslot:seeded' "$1"
}

if [ -x "$ENV_TEMPLATE_SCRIPT" ] &&
  { [ ! -f "$ENV_FILE" ] ||
    { ! env_file_is_seeded "$ENV_FILE" && env_file_is_machine_written "$ENV_FILE"; }; }; then
  generated_key_line=""
  if [ -f "$ENV_FILE" ]; then
    generated_key_line=$(grep '^DATA_ENCRYPTION_KEY=' "$ENV_FILE" || true)
  fi

  # Everything this app already has configured goes into the file too, so it is
  # a complete picture rather than an empty form next to the real settings.
  seeded_now=1
  imported_lines=$("$ENV_TEMPLATE_SCRIPT" --import)

  {
    "$ENV_TEMPLATE_SCRIPT" --template
    if [ -n "$generated_key_line" ]; then
      printf '\n%s\n' "$generated_key_line"
    fi
    if [ -n "$imported_lines" ]; then
      printf '%s\n' "$imported_lines"
    fi
  } > "${ENV_FILE}.tmp"

  chmod 600 "${ENV_FILE}.tmp"
  mv "${ENV_FILE}.tmp" "$ENV_FILE"
  echo "==> Seeded $ENV_FILE from the packaged template"

  imported_keys=$(printf '%s\n' "$imported_lines" |
    grep -oE '^[A-Z][A-Z_0-9]*=' | tr -d '=' | tr '\n' ' ' | sed 's/ $//')
  if [ -n "$imported_keys" ]; then
    echo "==> Copied the variables this app already has set into $ENV_FILE:"
    echo "==>   $imported_keys"
    echo "==> Cloudron still supplies them and still takes precedence, so nothing"
    echo "==> has changed. To manage them in the file from now on, hand them over"
    echo "==> from your workstation:"
    echo "==>   cloudron env unset --app ${CLOUDRON_APP_DOMAIN:-<your-app-domain>} $imported_keys"
  fi
fi

# Encodes one \uXXXX codepoint as UTF-8 in utf8_bytes. Bash's own `printf
# \uXXXX` is locale-dependent and prints the escape verbatim under LANG=C, so
# the bytes are assembled by hand; DotenvLoader produces UTF-8 whatever the
# locale, and mirrors this arithmetic byte for byte so the two cannot drift.
# Four hex digits reach 0xFFFF at most, so three bytes always suffice.
dotenv_utf8() {
  local codepoint=$((16#$1)) octal

  if [ "$codepoint" -lt 128 ]; then
    printf -v octal '\\%03o' "$codepoint"
  elif [ "$codepoint" -lt 2048 ]; then
    printf -v octal '\\%03o\\%03o' \
      $((192 + codepoint / 64)) $((128 + codepoint % 64))
  else
    printf -v octal '\\%03o\\%03o\\%03o' \
      $((224 + codepoint / 4096)) $((128 + codepoint / 64 % 64)) $((128 + codepoint % 64))
  fi

  # printf -v, unlike $(...), keeps a trailing newline the codepoint may be.
  printf -v utf8_bytes '%b' "$octal"
}

# Resolves the escape sequences a double-quoted dotenv value carries: \n \r \t
# \f \b become those characters, \uXXXX becomes that codepoint, \\ \" \' \$
# become the bare character, and a backslash before anything else is dropped.
# Without this the two readers would disagree on any secret holding a quote or
# a backslash, and this one runs first, so its value is the one the app would
# get. This function is the specification the release's own reader,
# Tymeslot.Infrastructure.DotenvLoader, implements; its test runs both over one
# fixture and compares, so a change here without a change there fails the suite.
#
# It is handed everything after the opening quote and stops at the first
# unescaped one. Answers on stdout would lose a trailing newline, so the value
# comes back in dotenv_value and whatever followed the closing quote in
# dotenv_tail. Returns 1 for input the release rejects too: a quote that never
# closes (a multi-line value, or a closing quote that was escaped) or a
# malformed \uXXXX.
dotenv_unescape() {
  local rest="$1" out="" chunk char hex
  local LC_ALL=C LANG=C

  while :; do
    case "$rest" in
      *[\\\"]*) chunk=${rest%%[\\\"]*} ;;
      *) return 1 ;;
    esac

    out="${out}${chunk}"
    rest="${rest#"$chunk"}"

    case "$rest" in
      \"*)
        dotenv_value="$out"
        dotenv_tail="${rest#\"}"
        return 0
        ;;
    esac

    rest="${rest#\\}"
    char="${rest:0:1}"
    rest="${rest:1}"
    case "$char" in
      '') return 1 ;;
      n) out="${out}"$'\n' ;;
      r) out="${out}"$'\r' ;;
      t) out="${out}"$'\t' ;;
      f) out="${out}"$'\f' ;;
      b) out="${out}"$'\b' ;;
      u)
        hex="${rest:0:4}"
        case "$hex" in
          [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f])
            dotenv_utf8 "$hex"
            out="${out}${utf8_bytes}"
            rest="${rest:4}"
            ;;
          *) return 1 ;;
        esac
        ;;
      *) out="${out}${char}" ;;
    esac
  done
}

# Applies KEY=value lines that name a variable which is not already set.
# Unterminated quotes (a multi-line value) are skipped rather than guessed at,
# by both readers: this one is line-oriented and cannot do otherwise, and
# DotenvLoader follows it rather than read the file two ways.
load_env_file() {
  local file="$1"
  local line key value rest tail file_applied=""
  local LC_ALL=C LANG=C

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
    rest="${value#"${value%%[![:space:]]*}"}"
    case "$rest" in
      # Double quotes carry escapes, so the value runs to the first unescaped
      # quote and is unescaped on the way; a line the release would reject is
      # skipped instead.
      \"*)
        dotenv_unescape "${rest#\"}" || continue
        value="$dotenv_value"
        tail="$dotenv_tail"
        ;;
      # Single quotes are literal on both sides, so the value runs to the next
      # quote. There is no escape for one, so a quote the value itself holds
      # leaves text after the close and the line is skipped below.
      \'*)
        rest="${rest#\'}"
        case "$rest" in
          *\'*) ;;
          *) continue ;;
        esac
        value="${rest%%\'*}"
        tail="${rest#*\'}"
        ;;
      # Unquoted, the comment is cut before the leading whitespace comes off,
      # so the space in `KEY= # note` still marks the `#` as a comment.
      *)
        value="${value%%[[:space:]]#*}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        tail=""
        ;;
    esac

    # After a closing quote only whitespace and a comment may follow.
    tail="${tail#"${tail%%[![:space:]]*}"}"
    case "$tail" in
      '' | '#'*) ;;
      *) continue ;;
    esac

    # A key repeated in one file takes its last value, which is what
    # DotenvLoader does when config/runtime.exs parses the same file. A key
    # already in the environment is left alone: the shell still wins.
    case " ${file_applied} " in
      *" ${key} "*)
        export "$key=$value"
        ;;
      *)
        if [ -z "${!key+set}" ]; then
          export "$key=$value"
          file_applied="${file_applied} ${key}"
          loaded_keys="${loaded_keys} ${key}"
        fi
        ;;
    esac
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

# Names the variables the app has but the file does not. Those are exactly the
# ones an operator would have to copy by hand before handing anything over to
# the file, so it is worth one line at boot rather than a discovery made after
# `cloudron env unset`. Mixing the two sources is a supported way to run, so
# this reports rather than warns.
report_variables_missing_from_env_file() {
  local file="$1"
  local key file_keys missing=""

  [ -f "$file" ] || return 0
  [ -x "$ENV_TEMPLATE_SCRIPT" ] || return 0

  file_keys=" $(grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$file" | tr -d ' =' | tr '\n' ' ')"

  for key in $("$ENV_TEMPLATE_SCRIPT" --import | grep -oE '^[A-Z][A-Z_0-9]*=' | tr -d '='); do
    case "$file_keys" in
      *" ${key} "*) ;;
      *) missing="${missing} ${key}" ;;
    esac
  done

  [ -n "$missing" ] || return 0

  echo "==> Set in this app's environment but not in ${file}:${missing}"
  echo "==> Copy them in with:"
  echo "==>   cloudron exec --app ${CLOUDRON_APP_DOMAIN:-<your-app-domain>} -- sh -c '${ENV_TEMPLATE_SCRIPT} --import ${file} >> ${file}'"

  return 0
}

if [ "$seeded_now" = 0 ]; then
  report_variables_missing_from_env_file "$ENV_FILE"
fi

# Warns when the .env supplies a key this container had previously generated
# for itself and the two differ. Such a line used to be ignored, because the
# generation below ran before anything read the file; now it takes effect, and
# that is worth one loud line at boot rather than a puzzling failure later.
warn_if_overrides_generated() {
  local key="$1" file="$2" consequence="$3"

  case " ${loaded_keys} " in
    *" ${key} "*) ;;
    *) return 0 ;;
  esac
  [ -f "$file" ] || return 0
  [ "$(cat "$file")" != "${!key}" ] || return 0

  echo "!!! WARNING: ${key} in ${ENV_FILE} differs from the value in ${file}."
  echo "!!! The file value is now in use; ${consequence}."
  echo "!!! Remove that line from ${ENV_FILE} and restart to return to the generated value."

  return 0
}

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
  warn_if_overrides_generated SECRET_KEY_BASE "$SECRET_FILE" \
    "every session signed with the previous secret is invalidated, logging all users out"
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
  warn_if_overrides_generated DATA_ENCRYPTION_KEY "$DATA_KEY_FILE" \
    "credentials encrypted under the generated key can no longer be decrypted"
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
