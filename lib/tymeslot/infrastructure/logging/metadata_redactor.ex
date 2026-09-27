defmodule Tymeslot.Infrastructure.Logging.MetadataRedactor do
  @moduledoc """
  Erlang `:logger` primary filter that scrubs sensitive keys out of a log
  event before it reaches any handler or formatter.

  Two parts of the event are scrubbed, both by key name:

  * `meta` — inline Logger metadata, the keys a call site passes itself, and
    the maps, keyword lists, lists, tuples and structs inside their values,
    to five levels down: `error: %{"access_token" => _}` is caught as surely
    as `access_token: _`.
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
  # opaque calendar event id and stays readable. `meeting_uid` is a bearer
  # capability: the meeting's uid alone authorises cancelling or rescheduling
  # it, and it is the route parameter of those pages, so it reaches request
  # and LiveView params as well as Logger metadata. A bare `uid` is not
  # matched: calendar event UIDs from other calendars carry no authority.
  @sensitive_exact_keys ~w(identifier meeting_uid)

  @redacted "[REDACTED]"
  @filter_id :tymeslot_metadata_redactor

  # Req's `auth:` option values. The credential is the second element whatever
  # key the tuple sits under, and `auth` itself is too short a name to match on.
  @auth_schemes [:bearer, :basic, :digest]

  # Metadata Logger and OTP set themselves. None of it is caller data, so it is
  # neither matched nor walked; walking it would be the bulk of the work on
  # every event for nothing. `crash_reason` is Logger's too, but its reason is
  # caller data: see `redact_crash_reason/1`.
  @logger_owned_keys [
    :mfa,
    :file,
    :line,
    :pid,
    :gl,
    :time,
    :domain,
    :application,
    :module,
    :function,
    :report_cb,
    :error_logger
  ]

  # What survives when redaction itself fails: correlation keys and Logger's
  # own, none of which can carry a secret.
  @fallback_keys [:request_id, :correlation_id, :user_id | @logger_owned_keys]
  @fallback_msg {:string, "[log event dropped: metadata redaction failed]"}

  # Keyed by the list's hash, so a code reload that changes the list compiles
  # a fresh pattern instead of matching against the stale one.
  @pattern_key {__MODULE__, :sensitive_pattern, :erlang.phash2(@sensitive_substrings)}

  # Deep enough for the report shapes that actually carry credentials (the
  # leak that prompted this sat four levels down) with room to spare, but
  # bounded so a pathologically nested term cannot make logging expensive.
  @max_depth 12

  # Metadata values are walked less deeply than message reports: they run for
  # every log event, and a call site's own metadata is rarely nested deeper
  # than a decoded API response. Five levels reaches a token in
  # `%{response: %{body: %{data: %{token: _}}}}` with room to spare.
  @meta_max_depth 5

  @max_key_bytes 128

  @struct_inspect_opts [limit: 50, printable_limit: 1_024]

  @doc """
  Installs the redactor as a primary `:logger` filter.

  Idempotent — safe to call on application restart inside the same BEAM.
  """
  @spec attach() :: :ok
  def attach do
    _patterns = sensitive_patterns()
    _previous = :logger.remove_primary_filter(@filter_id)
    :ok = :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, []})
  end

  @doc """
  Replaces the value of every sensitive key in `term` with `"[REDACTED]"`,
  walking maps, lists and tuples to the same bounded depth as the logger
  filter. Atom and string keys are matched alike.

  Key semantics apply to map entries and to `{key, value}` pairs inside a
  list (keyword lists, proplists, header lists). A tuple anywhere else is
  walked element by element, so `{:invalid_token, reason}` keeps its reason
  and `{%{"access_token" => _}, 200}` still loses its token. Req's auth
  tuples (`{:bearer, _}`, `{:basic, _}`, `{:digest, _}`) are redacted
  wherever they sit.

  A struct with its own `Inspect` implementation that has something redacted
  inside it is replaced by that implementation's rendering of the redacted
  struct, or by `"#Module<[REDACTED]>"` if the rendering fails. Such
  implementations often hide fields of their own (Req hides its `auth:`
  option), and a redacted value in a shape they do not expect makes them
  raise, at which point `inspect/2` falls back to printing the raw map.
  Exceptions are exempt and stay structs, since crash reporting needs them.

  Other stores that persist arbitrary diagnostic context (ErrorTracker
  occurrences) use this so they share one definition of "sensitive".
  """
  @spec redact(term()) :: term()
  def redact(term), do: redact_term(term, @max_depth)

  @doc """
  The nesting depth `redact/1` walks to. Terms nested deeper are left as they
  are, so a pathologically nested term cannot make redaction expensive.
  """
  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc false
  @spec filter(:logger.log_event(), term()) :: :logger.filter_return()
  def filter(event, _extra) when is_map(event), do: filter_with(event, &redact_event/1)

  def filter(event, _extra), do: event

  @doc false
  # Test seam: runs `redactor` under the guard `filter/2` uses. OTP removes a
  # primary filter that raises, which would switch redaction off for the rest
  # of the node's life, so nothing may escape; and the event must not go out
  # unredacted either, so a failure keeps only the metadata that cannot carry
  # a secret and replaces any message that is not a plain string.
  @spec filter_with(:logger.log_event(), (:logger.log_event() -> :logger.log_event())) ::
          :logger.log_event()
  def filter_with(event, redactor) do
    redactor.(event)
  catch
    _kind, _reason -> fallback_event(event)
  end

  defp redact_event(event) do
    event
    |> redact_event_meta()
    |> redact_event_msg()
  end

  defp fallback_event(event) do
    meta =
      case event do
        %{meta: meta} when is_map(meta) -> Map.take(meta, @fallback_keys)
        _no_meta -> %{}
      end

    msg =
      case event do
        %{msg: {:string, _chardata} = msg} -> msg
        _other -> @fallback_msg
      end

    Map.merge(event, %{meta: Map.put(meta, :redaction_failed, true), msg: msg})
  end

  defp redact_event_meta(%{meta: meta} = event) when is_map(meta),
    do: %{event | meta: redact_meta(meta)}

  defp redact_event_meta(event), do: event

  defp redact_event_msg(%{msg: {:report, report}} = event),
    do: %{event | msg: {:report, redact_term(report, @max_depth)}}

  defp redact_event_msg(%{msg: {:string, _chardata}} = event), do: event

  defp redact_event_msg(%{msg: {format, args}} = event) when is_list(args),
    do: %{event | msg: {format, redact_term(args, @max_depth)}}

  defp redact_event_msg(event), do: event

  # The metadata map itself is one level above its values, so its keys are
  # checked here and each value is walked to `@meta_max_depth` below that.
  defp redact_meta(meta) do
    :maps.map(
      fn
        key, value when key in @logger_owned_keys -> value
        :crash_reason, value -> redact_crash_reason(value)
        key, value -> redact_entry(key, value, @meta_max_depth)
      end,
      meta
    )
  end

  # `{reason, stacktrace}`, which CrashReporter records only while the
  # stacktrace is still a list. The stacktrace is never walked: redacting any
  # part of it would cost the crash its record.
  defp redact_crash_reason({reason, stacktrace}) when is_list(stacktrace),
    do: {redact_term(reason, @meta_max_depth - 1), stacktrace}

  defp redact_crash_reason(other), do: redact_term(other, @meta_max_depth)

  defp redact_term(term, depth) when depth <= 0, do: term

  defp redact_term(%module{} = struct, depth), do: redact_struct(module, struct, depth)

  defp redact_term(term, depth) when is_map(term), do: redact_map(term, depth)

  defp redact_term(term, depth) when is_list(term), do: redact_list(term, depth)

  defp redact_term({scheme, _credential}, _depth) when scheme in @auth_schemes,
    do: {scheme, @redacted}

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
    do: [redact_element(head, depth - 1) | redact_list(tail, depth)]

  defp redact_list([], _depth), do: []

  defp redact_list(improper_tail, depth), do: redact_term(improper_tail, depth - 1)

  # A pair inside a list is a keyword, proplist or header entry: the one place
  # outside a map where the first element is a key.
  defp redact_element({key, value}, depth) when depth > 0 and key not in @auth_schemes do
    if sensitive_key?(key),
      do: {key, redact_sensitive(value, depth - 1)},
      else: {redact_term(key, depth - 1), redact_term(value, depth - 1)}
  end

  defp redact_element(term, depth), do: redact_term(term, depth)

  # `:maps.map/2` rather than `Map.new/2` because a struct is a map that does
  # not implement `Enumerable`: an exception or a `%Req.Request{}` nested in a
  # crash report would raise here. It also keeps every key it was given,
  # `__struct__` included, so a struct stays the struct it was.
  defp redact_map(term, depth),
    do: :maps.map(fn key, value -> redact_entry(key, value, depth - 1) end, term)

  defp redact_entry(key, value, depth) do
    if sensitive_key?(key),
      do: redact_sensitive(value, depth),
      else: redact_term(value, depth)
  end

  # A changeset error (`password: {"is too short", [count: 8]}`) sits under the
  # field's name but carries only the validation message, never the value.
  defp redact_sensitive({message, opts}, depth) when is_binary(message) and is_list(opts) do
    if Keyword.keyword?(opts),
      do: {message, redact_term(opts, depth)},
      else: @redacted
  end

  defp redact_sensitive(_value, _depth), do: @redacted

  defp redact_struct(module, struct, depth) do
    redacted = redact_map(struct, depth)

    cond do
      redacted == struct -> struct
      is_exception(struct) -> redacted
      custom_inspect?(struct) -> render_struct(module, redacted)
      true -> redacted
    end
  end

  defp custom_inspect?(struct), do: Inspect.impl_for(struct) != Inspect.Any

  # Calls the implementation directly, not through `inspect/2`, because the
  # latter rescues a raising implementation and prints the raw map instead:
  # the very fields the implementation exists to hide.
  defp render_struct(module, redacted) do
    impl = Inspect.impl_for(redacted)
    opts = Inspect.Opts.new(@struct_inspect_opts)

    redacted
    |> impl.inspect(opts)
    |> Inspect.Algebra.format(opts.width)
    |> IO.iodata_to_binary()
  catch
    _kind, _reason -> "#" <> inspect(module) <> "<" <> @redacted <> ">"
  end

  defp sensitive_key?(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> sensitive_key?()
  end

  # A key longer than any sensitive name could be is data, not a name (a map
  # keyed by a response body, say), and downcasing it on every log event
  # would cost more than the rest of the walk.
  defp sensitive_key?(key) when is_binary(key) and byte_size(key) <= @max_key_bytes do
    {sensitive, uppercase} = sensitive_patterns()
    downcased = downcase(key, uppercase)

    :binary.match(downcased, sensitive) != :nomatch or
      downcased in @sensitive_exact_keys or
      Enum.any?(@sensitive_key_suffixes, &suffix_match?(downcased, &1))
  end

  defp sensitive_key?(_other), do: false

  # Every sensitive name is ASCII, so ASCII case folding is all the match
  # needs, and nearly every key is already lower case: checking for an
  # upper-case letter costs a tenth of downcasing unconditionally.
  defp downcase(key, uppercase) do
    case :binary.match(key, uppercase) do
      :nomatch -> key
      _found -> String.downcase(key, :ascii)
    end
  end

  # `String.contains?/2` with a list compiles a fresh matcher on every call,
  # which costs hundreds of times the match itself; this runs for every key of
  # every log event, so the patterns are compiled once and kept.
  defp sensitive_patterns do
    case :persistent_term.get(@pattern_key, nil) do
      nil ->
        patterns = {
          :binary.compile_pattern(@sensitive_substrings),
          :binary.compile_pattern(Enum.map(?A..?Z, &<<&1>>))
        }

        :persistent_term.put(@pattern_key, patterns)
        patterns

      patterns ->
        patterns
    end
  end

  defp suffix_match?(key, suffix),
    do: key == suffix or String.ends_with?(key, "_" <> suffix)
end
