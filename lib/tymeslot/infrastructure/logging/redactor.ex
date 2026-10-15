defmodule Tymeslot.Infrastructure.Logging.Redactor do
  @moduledoc """
  Provides utilities for redacting sensitive information from logs.
  """

  # Key names whose value is a credential, matched anywhere in the name as
  # MetadataRedactor matches them, so `webhook_secret`, `bot_token`,
  # `secret_key` and `password_confirmation` are all covered. A bare `*_key`
  # is not: `cache_key`, `dedup_key` and `idempotency_key` are logged for
  # diagnosis and carry no secret, so only the key names that do are listed.
  @secret_name "[a-z0-9_]*(?:secret|token|password|passcode|api_?key|private_key|encryption_key|signing_key)[a-z0-9_]*"

  # Error reports stored before a change here keep the old masking until
  # they are masked again: bump `ReasonScrubber`'s `@rules_version` with any
  # change to these patterns or to `@secret_name`.
  @sensitive_patterns [
    {~r/Bearer\s+[a-zA-Z0-9\-\._~+\/]+=*/i, "Bearer [REDACTED]"},
    {~r/Basic\s+[a-zA-Z0-9\-\._~+\/]+=*/i, "Basic [REDACTED]"},
    # A query parameter (`?token=`, `&client_secret=`), up to the next
    # parameter, whitespace or quote.
    {~r/\b(#{@secret_name})=(?!>)[^&\s"']+/i, "\\1=[REDACTED]"},
    # A bare query string ("code=abc&state=xyz") starts with its first
    # parameter, with no `?` in front of it.
    {~r/(^|[&\?])code=[^&\s"]+/i, "\\1code=[REDACTED]"},
    {~r/(^|[&\?])state=[^&\s"]+/i, "\\1state=[REDACTED]"},
    # A quoted value under a secret key name: `api_key: "…"` in an inspected
    # keyword list or atom-keyed map, `"api_key" => "…"`, JSON's
    # `"api_key":"…"`. The key must be followed by `:`, `=>` or `,` and not
    # preceded by `:`, so an atom such as `{:invalid_token, "Token expired"}`
    # keeps its message.
    {~r/(?<![:\w])"?(#{@secret_name})"?\s*(?::|=>|,)\s*"(?:[^"\\]++|\\.)*+"/i,
     "\\1: \"[REDACTED]\""}
  ]

  @doc """
  Redacts sensitive information from a string or inspected term.
  """
  @spec redact(binary()) :: binary()
  def redact(text) when is_binary(text) do
    Enum.reduce(@sensitive_patterns, text, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  @spec redact(any()) :: binary()
  def redact(term) do
    redact(inspect(term))
  end

  @doc """
  A short, non-reversible reference to a secret-bearing identifier, for logs.

  Some identifiers are credentials in their own right: a video room id is the
  join link for every link-based provider, so a log sink that records it hands
  whoever can read it a way into the call. Such an id must never be logged, but
  correlating two lines about the same room is still worth something to support,
  hence this: the first eight hex characters of its SHA-256.

  Stable across nodes and restarts, so the same id fingerprints alike wherever
  it is logged, and short enough that nobody mistakes it for the value itself.
  It is a correlation aid, not an identifier: eight characters collide, and
  nothing should key off one. Anything that is not a non-empty binary has no
  fingerprint and renders as `"none"`.

      iex> Tymeslot.Infrastructure.Logging.Redactor.fingerprint("room-123")
      "1bb12b94"
  """
  @spec fingerprint(any()) :: binary()
  def fingerprint(value) when is_binary(value) and value != "" do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 8)
  end

  def fingerprint(_value), do: "none"

  @doc """
  Standardized helper to redact and truncate a term for logging.
  """
  @spec redact_and_truncate(any(), integer()) :: binary()
  def redact_and_truncate(term, max_bytes \\ 2048) do
    term
    |> redact()
    |> truncate(max_bytes)
  end

  defp truncate(text, max_bytes) when is_binary(text) do
    if byte_size(text) > max_bytes do
      text
      |> binary_part(0, max_bytes)
      |> trim_invalid_trailing()
      |> Kernel.<>("... [TRUNCATED]")
    else
      text
    end
  end

  defp trim_invalid_trailing(binary) do
    if String.valid?(binary) do
      binary
    else
      trim_invalid_trailing(binary_part(binary, 0, byte_size(binary) - 1))
    end
  end
end
