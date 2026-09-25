defmodule Tymeslot.Infrastructure.Logging.MetadataRedactor do
  @moduledoc """
  Erlang `:logger` primary filter that scrubs sensitive keys out of a log
  event before it reaches any handler or formatter.

  Two parts of the event are scrubbed, both by key name:

  * `meta` — inline Logger metadata, the keys a call site passes itself.
  * `msg` — the message term, when it is a report (`Logger.info(%{...})`, and
    every OTP report) or a `{format, args}` pair. These are walked to any
    depth, because the terms that leak are nested: an OTP task-termination
    report carries the crashed function's arguments verbatim, and a calendar
    client sitting in those arguments carries the integration's decrypted
    CalDAV password. No application code authors those lines, so no call site
    has the chance to redact them.

  `{:string, _}` messages are deliberately left alone: there are no keys to
  match on, and scrubbing them means regex-matching every log line in the
  system. Message strings are `Tymeslot.Infrastructure.Logging.Redactor`'s job,
  at the call site that builds them.

  So a careless

      Logger.error("oauth failed", api_key: secret, password: pw)

  ships `[REDACTED]` to stdout, and so does a crash report that happens to
  carry a credential in a nested argument.

  Sensitive keys are matched case-insensitively against the key name
  (atom or string). Substring matching catches variants like `stripe_api_key`,
  `refresh_token`, `set_cookie`, `x_authorization`.

  Personal identifiers (`email`, `identifier`) are matched more precisely than
  secrets, because "email" appears in plenty of key names that carry no address
  at all. See `@sensitive_key_suffixes` and `@sensitive_exact_keys` below.

  A key whose value the writer has already masked is named with a `_masked`
  suffix by convention (`email_masked`, `owner_email_masked`,
  `identifier_masked`); none of the rules below matches such a key, so the
  masked value survives to the log line. Masking at source is the primary
  defence — this filter only catches what a call site forgot.
  """

  # `calendar_id`, `calendar_path` and `feed_url` are personal identifiers,
  # not secrets: Google calendar ids are email addresses, CalDAV paths can
  # embed the account username, and an ICS feed URL is a capability URL that
  # grants anyone holding it read access to the calendar. Redacting by key
  # keeps them out of structured logs; `calendar_integration_id` (not matched)
  # remains for correlation.
  @sensitive_substrings ~w(
    password
    passcode
    secret
    api_key
    apikey
    token
    authorization
    auth_header
    cookie
    private_key
    client_secret
    refresh_token
    access_token
    session_id
    calendar_id
    calendar_path
    feed_url
  )

  # Matched on the whole key or on a `_`-anchored suffix, never as a bare
  # substring: `attendee_email`, `organizer_email` and `new_email` all carry an
  # address, while `email_action`, `email_type` and `email_masked` do not, and
  # blanking those would cost diagnostics for no privacy gain.
  @sensitive_key_suffixes ~w(email)

  # Matched on the whole key only. `identifier` is the key the account-lockout
  # and rate-limiter paths use for an email address; `provider_identifier` is an
  # opaque calendar event id and stays readable.
  @sensitive_exact_keys ~w(identifier)

  @redacted "[REDACTED]"
  @filter_id :tymeslot_metadata_redactor

  # Deep enough for the report shapes that actually carry credentials (the
  # leak that prompted this sat four levels down) with room to spare, but
  # bounded so a pathologically nested term cannot make logging expensive.
  @max_depth 12

  @doc """
  Installs the redactor as a primary `:logger` filter.

  Idempotent — safe to call on application restart inside the same BEAM.
  """
  @spec attach() :: :ok
  def attach do
    _previous = :logger.remove_primary_filter(@filter_id)
    :ok = :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, []})
  end

  @doc false
  @spec filter(:logger.log_event(), term()) :: :logger.filter_return()
  def filter(event, _extra) when is_map(event) do
    event
    |> redact_event_meta()
    |> redact_event_msg()
  end

  def filter(event, _extra), do: event

  defp redact_event_meta(%{meta: meta} = event) when is_map(meta),
    do: %{event | meta: redact_meta(meta)}

  defp redact_event_meta(event), do: event

  defp redact_event_msg(%{msg: {:report, report}} = event),
    do: %{event | msg: {:report, redact_term(report, @max_depth)}}

  defp redact_event_msg(%{msg: {:string, _chardata}} = event), do: event

  defp redact_event_msg(%{msg: {format, args}} = event) when is_list(args),
    do: %{event | msg: {format, redact_term(args, @max_depth)}}

  defp redact_event_msg(event), do: event

  defp redact_term(term, depth) when depth <= 0, do: term

  defp redact_term(term, depth) when is_map(term), do: redact_map(term, depth)

  defp redact_term(term, depth) when is_list(term), do: redact_list(term, depth)

  defp redact_term({key, value}, depth) do
    if sensitive_key?(key), do: {key, @redacted}, else: {key, redact_term(value, depth - 1)}
  end

  defp redact_term(term, depth) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.map(&redact_term(&1, depth - 1))
    |> List.to_tuple()
  end

  defp redact_term(term, _depth), do: term

  # Hand-rolled rather than `Enum.map/2` so that an improper list — chardata
  # is routinely one — keeps its tail instead of raising inside the logger,
  # and so that list elements are siblings rather than each one level deeper.
  defp redact_list([head | tail], depth),
    do: [redact_term(head, depth - 1) | redact_list(tail, depth)]

  defp redact_list([], _depth), do: []

  defp redact_list(improper_tail, depth), do: redact_term(improper_tail, depth - 1)

  # `:maps.map/2` rather than `Map.new/2` because a struct is a map that does
  # not implement `Enumerable`: an exception or a `%Req.Request{}` nested in a
  # crash report would raise here. It also keeps every key it was given,
  # `__struct__` included, so a struct stays the struct it was.
  defp redact_map(term, depth) do
    :maps.map(
      fn key, value ->
        if sensitive_key?(key), do: @redacted, else: redact_term(value, depth - 1)
      end,
      term
    )
  end

  defp redact_meta(meta) do
    if Enum.any?(meta, fn {k, _v} -> sensitive_key?(k) end) do
      Map.new(meta, fn {key, value} ->
        if sensitive_key?(key) do
          {key, @redacted}
        else
          {key, value}
        end
      end)
    else
      meta
    end
  end

  defp sensitive_key?(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> sensitive_key?()
  end

  defp sensitive_key?(key) when is_binary(key) do
    downcased = String.downcase(key)

    Enum.any?(@sensitive_substrings, &String.contains?(downcased, &1)) or
      downcased in @sensitive_exact_keys or
      Enum.any?(@sensitive_key_suffixes, &suffix_match?(downcased, &1))
  end

  defp sensitive_key?(_other), do: false

  defp suffix_match?(key, suffix),
    do: key == suffix or String.ends_with?(key, "_" <> suffix)
end
