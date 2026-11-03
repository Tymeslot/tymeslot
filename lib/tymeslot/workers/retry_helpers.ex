defmodule Tymeslot.Workers.RetryHelpers do
  @moduledoc """
  Shared helpers for worker retry/backoff decisions.

  The HTTP client encodes a server-provided `Retry-After` (in seconds) as
  `retry_after:N` inside rate-limit error messages. Several workers need to read
  that value back out; this module is the single source of truth for parsing it
  so the regex and "positive integer" contract can't drift between callers.
  Default and bounds differ legitimately per provider, so each caller passes its
  own to `clamp_retry_after/2`; the clamping itself lives here.
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

  @doc """
  Reads the `retry_after:N` seconds value from the job's most recent recorded
  error, or `nil` when there is none.
  """
  @spec parse_retry_after_from_last_error(Oban.Job.t()) :: pos_integer() | nil
  def parse_retry_after_from_last_error(%Oban.Job{errors: errors}) do
    case List.last(errors) do
      %{"error" => message} -> parse_retry_after_from_message(message)
      _no_error -> nil
    end
  end

  @doc """
  The number of seconds to wait for a provider-supplied `Retry-After` value.

  An integer is clamped to `:min` (default 0) and `:max`; anything else,
  `nil` included, yields `:default`. Both `:max` and `:default` are required,
  since each provider's quota sets its own.
  """
  @spec clamp_retry_after(term(), keyword()) :: non_neg_integer()
  def clamp_retry_after(seconds, opts) when is_integer(seconds) do
    seconds
    |> max(Keyword.get(opts, :min, 0))
    |> min(Keyword.fetch!(opts, :max))
  end

  def clamp_retry_after(_other, opts), do: Keyword.fetch!(opts, :default)
end
