defmodule Tymeslot.Infrastructure.Logging.Redactor do
  @moduledoc """
  Provides utilities for redacting sensitive information from logs.
  """

  @sensitive_patterns [
    {~r/Bearer\s+[a-zA-Z0-9\-\._~+\/]+=*/i, "Bearer [REDACTED]"},
    {~r/Basic\s+[a-zA-Z0-9\-\._~+\/]+=*/i, "Basic [REDACTED]"},
    {~r/token=[a-zA-Z0-9\-\._~+\/]+=*/i, "token=[REDACTED]"},
    {~r/([&\?])code=[^&\s"]+/i, "\\1code=[REDACTED]"},
    {~r/([&\?])state=[^&\s"]+/i, "\\1state=[REDACTED]"},
    {~r/"?access_token"?[^a-zA-Z0-9]+"[^"]+"/i, "access_token: \"[REDACTED]\""},
    {~r/"?refresh_token"?[^a-zA-Z0-9]+"[^"]+"/i, "refresh_token: \"[REDACTED]\""},
    {~r/"?client_secret"?[^a-zA-Z0-9]+"[^"]+"/i, "client_secret: \"[REDACTED]\""},
    {~r/"?api_key"?[^a-zA-Z0-9]+"[^"]+"/i, "api_key: \"[REDACTED]\""}
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
