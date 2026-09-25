# shellcheck shell=bash
#
# The shell reader for a `.env` file, sourced by both container entrypoints:
# `start.sh` (Cloudron) and `start-docker.sh` (Docker). Both apply
# /app/data/.env before the release boots, and one copy of the reader is what
# keeps them agreeing with each other and with the release's own reader,
# Tymeslot.Infrastructure.DotenvLoader, which DotenvLoaderTest compares against
# this file byte for byte.
#
# Defines functions only; sourcing it has no side effects. `load_env_file`
# appends each key it applies to the caller's `loaded_keys`.

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
