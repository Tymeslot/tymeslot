defmodule Tymeslot.Infrastructure.ErrorTracking.Filter do
  @moduledoc """
  Sanitises an ErrorTracker occurrence's context before it is stored.

  The context is whatever the integrations and `ErrorTracker.set_context/1`
  gathered: request headers and params, LiveView params, Oban job args. Two
  passes, each reusing the rule the rest of the system already applies:

  1. `Tymeslot.Infrastructure.Logging.MetadataRedactor.redact/1` blanks every
     value under a sensitive key (credentials, tokens, cookies, `*_email`),
     for atom and string keys alike.
  2. `Tymeslot.Infrastructure.AdminAlerts.PIIScrubber.mask_emails/1` masks any
     email address left in a string value.

  Both walk maps, lists and tuples to the redactor's depth bound. Keys are
  never rewritten, so the stored context keeps its shape.

  ## Failing closed

  ErrorTracker calls this without a rescue, from telemetry handlers that
  telemetry detaches on the first raise. A bug here must therefore never
  escape (it would switch error tracking off until the next restart), and it
  must never let the unsanitised context through either. On any failure the
  occurrence is stored with `%{"context_redaction_failed" => true}`
  as its whole context, and a warning naming only the exception is logged.
  """

  @behaviour ErrorTracker.Filter

  alias Tymeslot.Infrastructure.AdminAlerts.PIIScrubber
  alias Tymeslot.Infrastructure.Logging.MetadataRedactor

  require Logger

  @failed_context %{"context_redaction_failed" => true}

  @impl ErrorTracker.Filter
  def sanitize(context), do: sanitize_with(context, &redact/1)

  @doc false
  # Test seam: runs `sanitiser` with the fail-closed guard `sanitize/1` uses,
  # so the guard can be exercised without a context that breaks redaction.
  @spec sanitize_with(map(), (map() -> map())) :: map()
  def sanitize_with(context, sanitiser) do
    sanitiser.(context)
  rescue
    exception ->
      Logger.warning("ErrorTracker context redaction failed; context discarded",
        exception: inspect(exception.__struct__)
      )

      @failed_context
  end

  defp redact(context) do
    context
    |> MetadataRedactor.redact()
    |> mask_emails(MetadataRedactor.max_depth())
  end

  # Same traversal as MetadataRedactor.redact/1: bounded depth, list elements
  # as siblings, improper tails kept, tuples walked, structs kept intact.
  defp mask_emails(term, depth) when depth <= 0, do: term
  defp mask_emails(term, _depth) when is_binary(term), do: PIIScrubber.mask_emails(term)

  defp mask_emails(term, depth) when is_map(term),
    do: :maps.map(fn _key, value -> mask_emails(value, depth - 1) end, term)

  defp mask_emails(term, depth) when is_list(term), do: mask_list(term, depth)

  defp mask_emails(term, depth) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.map(&mask_emails(&1, depth - 1))
    |> List.to_tuple()
  end

  defp mask_emails(term, _depth), do: term

  defp mask_list([head | tail], depth),
    do: [mask_emails(head, depth - 1) | mask_list(tail, depth)]

  defp mask_list([], _depth), do: []
  defp mask_list(improper_tail, depth), do: mask_emails(improper_tail, depth - 1)
end
