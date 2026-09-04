#!/bin/bash
#
# Prints the operator configuration template for /app/data/.env, and with
# --import the variables this container already has set, as lines ready to go
# into that file.
#
# start.sh runs both when it seeds the file. An operator whose file predates
# seeding, or who wants the list a later release added, runs it themselves:
#
#   cloudron exec --app <domain> -- sh -c '/app/env-template.sh >> /app/data/.env'
#
# Giving --import the file it is being appended to skips the keys that file
# already assigns, so appending twice cannot leave two lines for one variable:
#
#   /app/env-template.sh --import /app/data/.env >> /app/data/.env
#
# The variable names come from the packaged .env.example, so this script needs
# no list of its own and cannot drift from the documented one.

set -eu

TEMPLATE_FILE="${ENV_TEMPLATE:-/app/.env.example}"

usage() {
  echo "usage: ${0##*/} [--template | --import [FILE-TO-APPEND-TO]]" >&2
  exit 64
}

# Variables the platform and the image own, never Tymeslot settings. Writing
# them into the file would pin values Cloudron expects to control and rotate:
# addon credentials above all, but also the port it routes to.
is_platform_var() {
  case "$1" in
    CLOUDRON_* | RELEASE_* | MIX_ENV | PHX_SERVER | DOCKER_ENV | DEPLOYMENT_TYPE | \
      PORT | LANG | LC_* | ELIXIR_ERL_OPTIONS | PATH | HOME | HOSTNAME | PWD | \
      OLDPWD | SHLVL | TERM | USER | _)
      return 0
      ;;
    *) return 1 ;;
  esac
}

known_variables() {
  grep -oE '^[[:space:]]*#?[[:space:]]*[A-Z][A-Z_0-9]*=' "$TEMPLATE_FILE" |
    tr -d ' #=' | sort -u
}

print_header() {
  cat <<'HEADER'
# tymeslot:seeded
# Tymeslot configuration
#
# Created from the packaged .env.example with every value commented out, so it
# changes nothing until you edit it. Uncomment the lines you need, then
# restart the app:
#
#   cloudron restart --app <your-app-domain>
#
# Variables set with `cloudron env set`, or on the dashboard's Environment
# tab, always win over the values below; use those for one-off overrides.
#
# Quote any value that is not a plain word. Single quotes are literal, so
# 'p@ss #1 $x' is exactly that; inside double quotes \n and \uXXXX are escape
# sequences, ${VAR} and $(cmd) are expanded unless written \$, and " and \
# must be written \" and \\. Unquoted, a value is cut at the first # and
# loses its backslashes. Use single quotes unless the value holds one.
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
}

print_template() {
  print_header
  sed 's/^\([A-Za-z_][A-Za-z0-9_]*=\)/# \1/' "$TEMPLATE_FILE"
}

# Quotes a value only when it needs it, so the common case stays readable.
#
# Single quotes are the default, because both readers of this file agree on
# them byte for byte: a single-quoted dotenv value is literal, with no escape
# sequences, no ${VAR} interpolation and no $(cmd) substitution, in Dotenvy
# (which parses the file inside the release) and in start.sh's load_env_file
# (which parses it before the release boots).
#
# A single quote cannot appear inside a single-quoted value: dotenv has no
# escape for it, and Dotenvy rejects the whole file rather than the one line.
# Such a value is double-quoted instead, with \\, \" and \$ escaped; those are
# the escapes load_env_file understands, and Dotenvy resolves them the same
# way. Escaping $ is what keeps Dotenvy from treating ${...} or $(...) in a
# secret as something to expand.
format_assignment() {
  local key="$1" value="$2" escaped

  case "$value" in
    *[!A-Za-z0-9_/.:@+=-]*)
      case "$value" in
        *\'*)
          escaped="${value//\\/\\\\}"
          escaped="${escaped//\"/\\\"}"
          escaped="${escaped//\$/\\\$}"
          printf '%s="%s"\n' "$key" "$escaped"
          ;;
        *) printf "%s='%s'\n" "$key" "$value" ;;
      esac
      ;;
    *) printf '%s=%s\n' "$key" "$value" ;;
  esac
}

# Keys already assigned in the file being appended to. Collected up front, so
# appending the output back into that same file cannot read what it just wrote.
assigned_keys() {
  local file="$1"

  [ -f "$file" ] || return 0
  grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "$file" | tr -d ' =' | sort -u
}

print_import() {
  local key value header_printed=0 existing=""

  if [ -n "${1:-}" ]; then
    existing=" $(assigned_keys "$1" | tr '\n' ' ')"
  fi

  for key in $(known_variables); do
    is_platform_var "$key" && continue
    [ -n "${!key+set}" ] || continue
    case "$existing" in
      *" ${key} "*) continue ;;
    esac

    value="${!key}"
    case "$value" in
      *$'\n'*)
        echo "${0##*/}: skipping ${key}, its value spans several lines" >&2
        continue
        ;;
    esac

    if [ "$header_printed" = 0 ]; then
      cat <<'IMPORT'

# ---------------------------------------------------------------------------
# Imported from this app's environment when the file was created.
#
# These are the values Cloudron was already supplying, copied here so the file
# is a complete configuration. Cloudron still supplies them and still wins, so
# editing one here changes nothing until you hand it over:
#
#   cloudron env unset --app <your-app-domain> KEY [KEY...]
#
# The boot log names the exact command for this app.
# ---------------------------------------------------------------------------
IMPORT
      header_printed=1
    fi

    format_assignment "$key" "$value"
  done
}

case "${1:---template}" in
  --template) print_template ;;
  --import) print_import "${2:-}" ;;
  *) usage ;;
esac
