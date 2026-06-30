defmodule Tymeslot.Workers.RetryHelpers do
  @moduledoc """
  Shared helpers for worker retry/backoff decisions.

  The HTTP client encodes a server-provided `Retry-After` (in seconds) as
  `retry_after:N` inside rate-limit error messages. Several workers need to read
  that value back out; this module is the single source of truth for parsing it
  so the regex and "positive integer" contract can't drift between callers.
  Default and cap policy stays with each caller, since they differ legitimately.
  """

  # Tolerates `retry_after:30`, `retry after: 30`, `retry-after  30`, etc.
  @retry_after_regex ~r/retry[_\s]after[:\s]+(\d+)/i

  @doc """
  Extracts the `retry_after:N` seconds value from an error/rate-limit message.

  Returns the positive integer number of seconds, or `nil` when the message is
  not a binary, contains no `retry_after` marker, or encodes a non-positive
  value. Callers apply their own default and upper bound.
  """
  @spec parse_retry_after_from_message(term()) :: pos_integer() | nil
  def parse_retry_after_from_message(message) when is_binary(message) do
    case Regex.run(@retry_after_regex, message) do
      [_full, seconds] ->
        case Integer.parse(seconds) do
          {n, _rest} when n > 0 -> n
          _non_positive -> nil
        end

      _no_match ->
        nil
    end
  end

  def parse_retry_after_from_message(_other), do: nil
end
