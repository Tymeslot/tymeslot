defmodule Tymeslot.Infrastructure.Logging.LogFormat do
  @moduledoc """
  Renders arbitrary terms as Logger metadata values.

  An error reason logged as `reason: inspect(reason)` is a string by the
  time it reaches `MetadataRedactor`, so the filter can no longer see the
  keys inside it: an `{:error, %{"access_token" => _}}` from a provider goes
  out whole. `reason/1` redacts the term before it becomes a string, with the
  filter's own key rules, and scrubs the string afterwards for what only
  shows up in text (bearer headers, query-string tokens, email addresses).

      Logger.error("Token refresh failed", reason: LogFormat.reason(reason))

  The output is bounded, so a reason that carries a whole HTTP response body
  cannot turn one log line into megabytes.

  Every call is a runtime call: nothing here is a macro, so using the module
  adds no compile-time dependency to its callers.
  """

  alias Tymeslot.Infrastructure.AdminAlerts.PIIScrubber
  alias Tymeslot.Infrastructure.Logging.MetadataRedactor
  alias Tymeslot.Infrastructure.Logging.Redactor

  # Per collection and per string respectively; the byte cap below bounds
  # the whole, since a nested term multiplies the per-collection limit.
  @inspect_opts [limit: 50, printable_limit: 1_024]
  @max_bytes 4_096

  @doc """
  Inspects `term` for a log line, with sensitive values redacted and the
  output bounded to #{@max_bytes} bytes.
  """
  @spec reason(term()) :: String.t()
  def reason(term) do
    term
    |> MetadataRedactor.redact()
    |> inspect(@inspect_opts)
    |> PIIScrubber.mask_emails()
    |> Redactor.redact_and_truncate(@max_bytes)
  end

  @doc """
  Formats `stacktrace` for a log line with every frame's arguments reduced to
  their count.

  A frame can carry the call's arguments in place of its arity (the top
  frame of a `FunctionClauseError` does), and `Exception.format_stacktrace/1`
  and `Exception.format/3` print them inspected: a crash while applying a
  calendar event puts the whole event, attendees' addresses included, into
  the log line. The arity says which clause was called without that.
  """
  @spec stacktrace(Exception.stacktrace()) :: String.t()
  def stacktrace(stacktrace) when is_list(stacktrace) do
    stacktrace
    |> Enum.map(&without_arguments/1)
    |> Exception.format_stacktrace()
  end

  defp without_arguments({module, function, args, location}) when is_list(args),
    do: {module, function, length(args), location}

  defp without_arguments({function, args, location}) when is_list(args),
    do: {function, length(args), location}

  defp without_arguments(frame), do: frame
end
