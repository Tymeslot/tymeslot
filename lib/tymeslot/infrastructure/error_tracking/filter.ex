defmodule Tymeslot.Infrastructure.ErrorTracking.Filter do
  @moduledoc """
  Sanitises an ErrorTracker occurrence's context before it is stored.

  The context is whatever the integrations and `ErrorTracker.set_context/1`
  gathered: request headers and params, LiveView params, Oban job args. Four
  passes, each reusing the rule the rest of the system already applies:

  1. `Tymeslot.Infrastructure.Logging.MetadataRedactor.redact/1` blanks every
     value under a sensitive key (credentials, tokens, cookies, `*_email`),
     for atom and string keys alike.
  2. `Tymeslot.Infrastructure.Logging.PathMasker.mask/1` masks capability
     segments (meeting uids, link tokens) in the recorded `request.path` and
     `live_view.uri`, and in the URL-bearing request headers (`referer`,
     `origin` and the proxies' original-URL headers): a page linked from a
     password reset or a meeting's cancel link sends that link as its
     Referer.
  3. Every string value is scrubbed: `PIIScrubber.mask_emails/1` masks any
     email address in it, and `Tymeslot.Infrastructure.Logging.Redactor`
     blanks credentials embedded in text, such as `code=` and `state=` in a
     recorded `request.query` or a bearer token in a message.
  4. The visitor's IP address is blanked: ErrorTracker's own `request.ip`,
     and the forwarding headers that carry it (`x-forwarded-for` and the
     like). A log line keeps the truncated network, but an occurrence is
     kept for as long as its error keeps recurring, and nothing about
     debugging an error needs to know who hit it.

  The first and third walk maps, lists and tuples to the redactor's depth
  bound. Keys are never rewritten, so the stored context keeps its shape.

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
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Logging.MetadataRedactor
  alias Tymeslot.Infrastructure.Logging.PathMasker
  alias Tymeslot.Infrastructure.Logging.Redactor

  require Logger

  @failed_context %{"context_redaction_failed" => true}

  # Paths ErrorTracker's integrations record, which can carry a capability.
  @path_keys ["request.path", "live_view.uri"]

  # Where ErrorTracker's Plug integration records the client's address.
  @ip_key "request.ip"

  # Request headers that carry the client's address on its way through a
  # proxy. ErrorTracker records header names as Plug gives them, lower case.
  @ip_headers ~w(x-forwarded-for x-real-ip forwarded true-client-ip cf-connecting-ip)

  @redacted "[REDACTED]"

  # Request headers whose value is a URL or path. ErrorTracker records header
  # names as Plug gives them, lower case.
  @url_headers ~w(referer origin x-original-url x-rewrite-url x-forwarded-uri x-forwarded-url)

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
        exception: LogFormat.reason(exception.__struct__)
      )

      @failed_context
  end

  defp redact(context) do
    context
    |> MetadataRedactor.redact()
    |> mask_paths()
    |> scrub_strings(MetadataRedactor.max_depth())
    |> strip_client_ip()
  end

  defp strip_client_ip(context) when is_map(context) do
    context
    |> blank_keys([@ip_key])
    |> update_headers(&blank_keys(&1, @ip_headers))
  end

  defp strip_client_ip(context), do: context

  defp blank_keys(map, keys) do
    Enum.reduce(keys, map, fn key, acc ->
      if Map.has_key?(acc, key), do: Map.put(acc, key, @redacted), else: acc
    end)
  end

  defp mask_paths(context) when is_map(context) do
    context
    |> mask_keys(@path_keys)
    |> mask_headers()
  end

  defp mask_paths(context), do: context

  defp mask_headers(context), do: update_headers(context, &mask_keys(&1, @url_headers))

  defp update_headers(%{"request.headers" => headers} = context, fun) when is_map(headers),
    do: %{context | "request.headers" => fun.(headers)}

  defp update_headers(context, _fun), do: context

  defp mask_keys(map, keys) do
    Enum.reduce(keys, map, fn key, acc ->
      case acc do
        %{^key => path} -> Map.put(acc, key, PathMasker.mask(path))
        _missing -> acc
      end
    end)
  end

  defp scrub_string(string) do
    string
    |> PIIScrubber.mask_emails()
    |> Redactor.redact()
  end

  # Same traversal as MetadataRedactor.redact/1: bounded depth, list elements
  # as siblings, improper tails kept, tuples walked, structs kept intact.
  defp scrub_strings(term, depth) when depth <= 0, do: term
  defp scrub_strings(term, _depth) when is_binary(term), do: scrub_string(term)

  defp scrub_strings(term, depth) when is_map(term),
    do: :maps.map(fn _key, value -> scrub_strings(value, depth - 1) end, term)

  defp scrub_strings(term, depth) when is_list(term), do: scrub_list(term, depth)

  defp scrub_strings(term, depth) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.map(&scrub_strings(&1, depth - 1))
    |> List.to_tuple()
  end

  defp scrub_strings(term, _depth), do: term

  defp scrub_list([head | tail], depth),
    do: [scrub_strings(head, depth - 1) | scrub_list(tail, depth)]

  defp scrub_list([], _depth), do: []
  defp scrub_list(improper_tail, depth), do: scrub_strings(improper_tail, depth - 1)
end
