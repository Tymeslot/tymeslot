defmodule Tymeslot.Integrations.Calendar.CalDAV.Events do
  @moduledoc """
  CalDAV event operations domain.

  Owns the full lifecycle of calendar event CRUD:

  - **ETag-conditional updates**: callers pass the cached ETag via `:etag`
    in `opts` for a direct conditional PUT with `If-Match`. When no cached
    ETag is available, the module falls back to a HEAD probe, then a GET
    for servers that refuse HEAD, and finally to `If-Match: *`. Prevents
    lost updates on concurrent edits.
  - **Conflict resolution policy**: on `412 Precondition Failed`, the
    caller chooses one of `:fail | :keep_server | :keep_local` via
    `:conflict_resolution` in `opts`. See `ConflictResolution` for the
    semantics of each value. A server that answers a conditional PUT with
    `409` instead of `412` follows the same policy when a real ETag was
    sent; when only `If-Match: *` was sent the write is simply replayed
    unconditionally, since that condition guarded nothing. The write itself
    is `ConditionalWrite`'s.
  - **Series writes**: one occurrence of a series is deleted or edited,
    every occurrence edited, or the series split in two for an edit of one
    occurrence and every following one, by rewriting the series' resource,
    see `delete_occurrence/4`, `update_occurrence/4`, `update_series/4` and
    `split_series/4` (carried out by `CalDAV.SeriesWrites`).
  - **iCal construction**: builds valid RFC 5545 event payloads from domain maps.
  - **Per-operation retry policies**: reads retry on transient failures.
  - **Circuit breaker protection** for all operations.

  Callers receive parsed domain types — never raw HTTP responses, XML, or iCal.
  """

  alias Tymeslot.Infrastructure.{CalendarCircuitBreaker, RetryLogic}

  alias Tymeslot.Integrations.Calendar.CalDAV.{
    Base,
    ConditionalWrite,
    ConflictResolution,
    EventProcessor,
    Http,
    Scheduling,
    SeriesWrites,
    UrlBuilder,
    XmlHandler
  }

  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.ICalBuilder

  require Logger

  @doc """
  Fetches events from a calendar within the given time range.

  Applies retry logic for transient failures — reads are safe to retry.
  Returns parsed event maps with domain fields (`uid`, `summary`, etc.).
  """
  @spec fetch_events(Base.client(), String.t(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, list(XmlHandler.parsed_event())} | {:error, Base.error_reason()}
  def fetch_events(client, calendar_path, start_time, end_time, opts \\ []) do
    result =
      with_events_breaker(client, opts, fn ->
        url = UrlBuilder.build_calendar_url(client.base_url, calendar_path)
        report_body = XmlHandler.build_calendar_query(start_time, end_time)

        retry_opts = Keyword.get(opts, :retry_opts, Base.default_retry_opts())

        report_opts =
          Keyword.put(opts, :timeout, Keyword.get(opts, :timeout, Base.report_timeout_ms()))

        case RetryLogic.with_retry(
               fn ->
                 Http.report(url, client.username, client.password, report_body, report_opts)
               end,
               retry_opts
             ) do
          {:ok, %Req.Response{status: 207, body: body}} ->
            XmlHandler.parse_calendar_query(body)

          {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
            # Some servers return 200 instead of the CalDAV-mandated 207 Multi-Status
            Logger.warning("CalDAV REPORT returned unexpected status",
              status: status,
              expected: 207,
              url: url,
              provider: Map.get(client, :provider, :caldav)
            )

            XmlHandler.parse_calendar_query(body)

          {:error, :not_found} ->
            # A missing calendar collection is a per-resource condition, not a
            # host outage — pass it through as success so it doesn't count
            # towards opening the host circuit breaker.
            {:ok, :calendar_not_found}

          {:error, reason} ->
            {:error, reason}
        end
      end)

    case result do
      {:ok, :calendar_not_found} -> {:error, :not_found}
      other -> other
    end
  end

  @doc """
  Creates a new event in the calendar.

  Generates a UID if not supplied in `event_data`. Returns
  `{:ok, %CreatedEvent{}}` on success, carrying the uid future updates and
  deletes address the event by, the href the resource was written to, and the
  ETag the server assigned it. Uses `If-None-Match: *` to prevent accidental
  overwrites.
  """
  @spec create_calendar_event(Base.client(), String.t(), map(), keyword()) ::
          {:ok, CreatedEvent.t()} | {:error, Base.error_reason()}
  def create_calendar_event(client, calendar_path, event_data, opts \\ []) do
    uid = event_data[:uid] || ICalBuilder.generate_uid()
    ical_data = ICalBuilder.build_simple_event(uid, event_data, Scheduling.attendee_mode(client))
    put_ical(client, calendar_path, uid, ical_data, opts)
  end

  @doc """
  Creates a new event in the calendar from a pre-built iCalendar payload.

  Skips `ICalBuilder` entirely — the caller is responsible for producing a
  valid RFC 5545 document. Used by `mix calendar_audit` to exercise
  adversarial server-generated payloads (e.g. Zimbra-style quoted TZIDs)
  that Tymeslot's own writer never produces.
  """
  @spec put_raw_event(Base.client(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, CreatedEvent.t()} | {:error, Base.error_reason()}
  def put_raw_event(client, calendar_path, uid, ical_data, opts \\ []) do
    put_ical(client, calendar_path, uid, ical_data, opts)
  end

  defp put_ical(client, calendar_path, uid, ical_data, opts) do
    with_events_breaker(client, opts, fn ->
      url = UrlBuilder.build_event_url(client.base_url, calendar_path, uid)
      put_opts = Keyword.merge([operation: :create], Keyword.take(opts, [:timeout]))

      case Http.put_event(url, client.username, client.password, ical_data, put_opts) do
        {:ok, %Req.Response{status: status, headers: headers}} when status in [200, 201, 204] ->
          {:ok, created_event(uid, calendar_path, url, headers)}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  # The PUT just addressed the resource, so its href is known without asking:
  # it is the URL reduced to a path, which is how sync spells a CalDAV
  # `provider_event_id` and what `event_url/4` expects back.
  #
  # The ETag is genuinely optional. RFC 4791 §5.3.4 only says a server SHOULD
  # return one, and a server that normalised the submitted document must not,
  # so its absence is an ordinary create: the update path still falls back to
  # the probe (HEAD, then GET) and then to `If-Match: *`.
  defp created_event(uid, calendar_path, url, headers) do
    CreatedEvent.new(uid,
      provider_event_id: href_path(url),
      calendar_id: calendar_path,
      etag: EventProcessor.clean_etag(ConditionalWrite.etag_from_headers(headers))
    )
  end

  defp href_path(url) do
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) and path != "" -> path
      _no_path -> url
    end
  end

  @doc """
  Updates an existing event.

  Uses a conditional `If-Match` write to prevent lost updates when two
  parties edit the same event concurrently. The caller should supply the
  cached ETag via `opts[:etag]`; when absent, the function falls back to a
  HEAD probe, then a GET, and finally to `If-Match: *` if neither finds one.

  ## Patched versus rebuilt

  An event that arrived by sync is **patched**: `event_data[:raw_ical]` is the
  document the provider last gave us, `ICalBuilder.patch_event_properties/3`
  rewrites the properties the payload carries, and the rest of the document —
  the `ATTENDEE` block with its `PARTSTAT`, `CATEGORIES`, `X-` properties —
  goes back untouched. Rebuilding it from the payload instead would erase all
  of that, since `build_simple_event/3` serialises what Tymeslot models and
  nothing else.

  An event with no `:raw_ical` is **rebuilt**, which is the right writer for a
  booking Tymeslot authored and the only one available before the first sync.

  A patched write is only ever applied to a document whose ETag we hold: the
  cached pair when the caller supplies both, otherwise the server's current
  copy, read first. A rejected precondition re-reads the event and patches
  that copy rather than forcing a stale document through, so the organiser's
  change lands on top of whatever else happened to the event instead of
  reverting it.
  """
  @spec update_calendar_event(Base.client(), String.t(), String.t(), map(), keyword()) ::
          :ok | {:error, Base.error_reason()}
  def update_calendar_event(client, calendar_path, uid, event_data, opts) do
    policy = Keyword.get(opts, :conflict_resolution, ConflictResolution.default())

    if ConflictResolution.valid?(policy) do
      with_events_breaker(client, opts, fn ->
        with {:ok, url} <- event_url(client, calendar_path, uid, event_data[:provider_event_id]) do
          write_update(client, url, uid, event_data, policy, opts)
        end
      end)
    else
      {:error, :invalid_conflict_resolution_policy}
    end
  end

  defp write_update(client, url, uid, event_data, policy, opts) do
    case cached_document(event_data) do
      {raw_ical, etag} when is_binary(etag) and etag != "" ->
        patch_and_put(client, url, uid, raw_ical, etag, event_data, policy, opts)

      # A cached document with no ETag carries no precondition, and
      # `If-Match: *` is not one: it would let a document older than the
      # server's through. The server's own copy comes with the ETag that makes
      # the write conditional, so it is read first.
      {_raw_ical, _no_etag} ->
        refresh_and_put(client, url, uid, event_data, policy, opts)

      :none ->
        rebuild_and_put(client, url, uid, event_data, policy, opts)
    end
  end

  defp patch_and_put(client, url, uid, raw_ical, etag, event_data, policy, opts) do
    ical_data = document_to_put(client, raw_ical, uid, event_data)

    case ConditionalWrite.put(client, url, ical_data, etag, :fail, opts) do
      {:error, reason} when reason in [:precondition_failed, :conditional_not_supported] ->
        resolve_stale_patch(client, url, uid, event_data, policy, opts)

      result ->
        result
    end
  end

  # The cached document lost the race. `:keep_server` asks for the server's
  # copy to stand, so there is nothing left to write; the other two policies
  # want the organiser's change, and it belongs on the copy that won rather
  # than on the one that lost.
  defp resolve_stale_patch(_client, _url, _uid, _event_data, :keep_server, _opts), do: :ok

  defp resolve_stale_patch(client, url, uid, event_data, policy, opts),
    do: refresh_and_put(client, url, uid, event_data, policy, opts)

  # The cached document is only as fresh as the last sync, and an edit of our
  # own leaves it a version behind, so this is the ordinary second write of an
  # event rather than an exceptional path.
  defp refresh_and_put(client, url, uid, event_data, policy, opts) do
    case ConditionalWrite.fetch_document(client, url, opts) do
      {:ok, raw_ical, etag} ->
        ical_data = document_to_put(client, raw_ical, uid, event_data)
        ConditionalWrite.put(client, url, ical_data, etag, policy, opts)

      {:error, :not_found} ->
        rebuild_and_put(client, url, uid, event_data, policy, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rebuild_and_put(client, url, uid, event_data, policy, opts) do
    ical_data = rebuild_document(client, uid, event_data)

    ConditionalWrite.put(
      client,
      url,
      ical_data,
      ConditionalWrite.resolve_etag(url, client, opts),
      policy,
      opts
    )
  end

  defp cached_document(event_data) do
    case Map.get(event_data, :raw_ical) do
      raw_ical when is_binary(raw_ical) and raw_ical != "" ->
        {raw_ical, Map.get(event_data, :etag)}

      _missing ->
        :none
    end
  end

  # A document with no VEVENT is nothing to patch — patching it would answer
  # `:ok` to a write that changed nothing — so the payload is serialised in
  # full instead.
  defp document_to_put(client, raw_ical, uid, event_data) do
    if String.contains?(raw_ical, "BEGIN:VEVENT") do
      ICalBuilder.patch_event_properties(raw_ical, event_data, Scheduling.attendee_mode(client))
    else
      rebuild_document(client, uid, event_data)
    end
  end

  defp rebuild_document(client, uid, event_data) do
    ICalBuilder.build_simple_event(
      uid,
      Map.put(event_data, :uid, uid),
      Scheduling.attendee_mode(client)
    )
  end

  @doc """
  Best-effort colour-only write-back for an existing event.

  Patches the RFC 7986 `COLOR` property on `opts[:raw_ical]` — the event's
  last-synced iCalendar document — and PUTs the result. Never rebuilds the
  VEVENT from a reduced payload the way `update_calendar_event/5` does; that
  would silently drop RRULE/ATTENDEE/VALARM data absent from a colour-only
  request. Returns `{:error, :raw_ical_unavailable}` when the caller has no
  cached `raw_ical` to patch (e.g. before the first full sync) so the caller
  can retry once a sync populates it.

  Uses the same conditional `If-Match` / conflict-resolution semantics as
  `update_calendar_event/5`; `opts[:provider_event_id]` is honoured the same
  way for resolving the event's URL.
  """
  @spec update_event_colour(Base.client(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, Base.error_reason() | :raw_ical_unavailable}
  def update_event_colour(client, calendar_path, uid, colour, opts) do
    case Keyword.get(opts, :raw_ical) do
      raw_ical when is_binary(raw_ical) and raw_ical != "" ->
        do_update_event_colour(client, calendar_path, uid, colour, raw_ical, opts)

      _missing ->
        {:error, :raw_ical_unavailable}
    end
  end

  defp do_update_event_colour(client, calendar_path, uid, colour, raw_ical, opts) do
    policy = Keyword.get(opts, :conflict_resolution, ConflictResolution.default())

    if ConflictResolution.valid?(policy) do
      with_events_breaker(client, opts, fn ->
        with {:ok, url} <- event_url(client, calendar_path, uid, opts[:provider_event_id]) do
          ical_data = ICalBuilder.replace_colour_property(raw_ical, colour)
          etag = ConditionalWrite.resolve_etag(url, client, opts)

          ConditionalWrite.put(client, url, ical_data, etag, policy, opts)
        end
      end)
    else
      {:error, :invalid_conflict_resolution_policy}
    end
  end

  @doc """
  Deletes an event from the calendar. Idempotent — succeeds if already gone.

  When `opts[:provider_event_id]` is set (the event's href on the server),
  the DELETE is routed to that exact URL. This is required when the event
  lives on a calendar other than `calendar_path` — a multi-calendar CalDAV
  integration stores events under different paths, and building the URL from
  `calendar_path` + `uid` would hit the wrong calendar. The server would then
  return 404, which our HTTP layer treats as idempotent success, silently
  leaving the event intact on its real calendar.
  """
  @spec delete_calendar_event(Base.client(), String.t(), String.t(), keyword()) ::
          :ok | {:error, Base.error_reason()}
  def delete_calendar_event(client, calendar_path, uid, opts) do
    with_events_breaker(client, opts, fn ->
      with {:ok, url} <- event_url(client, calendar_path, uid, opts[:provider_event_id]) do
        delete_opts = Keyword.take(opts, [:timeout])

        case Http.delete_event(url, client.username, client.password, delete_opts) do
          {:ok, %Req.Response{}} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    end)
  end

  @typedoc "One occurrence of the series stored at `href`, keyed as the cache keys it."
  @type occurrence :: SeriesWrites.occurrence()

  @doc """
  Deletes one occurrence of the series stored in the resource at
  `occurrence.href`, by rewriting the resource (see
  `ICalBuilder.Series.exclude_occurrence/3`) and PUTting it back under
  `If-Match`. Starts from `occurrence.document` and `occurrence.etag` when the
  cache holds both; otherwise, or when the server answers 412 because the
  resource moved on, re-reads it once and applies the exclusion to what the
  server holds. A resource left with nothing in it is deleted.

  Returns `{:ok, %{document: String.t() | nil}}` with the document now on the
  server (`nil` once the resource was deleted, or when it was already gone),
  or `{:error, reason}`.
  """
  @spec delete_occurrence(Base.client(), String.t() | nil, occurrence(), keyword()) ::
          {:ok, %{document: String.t() | nil}} | {:error, term()}
  defdelegate delete_occurrence(client, calendar_path, occurrence, opts), to: SeriesWrites

  @doc """
  Edits one occurrence of the series stored in the resource at
  `occurrence.href`: `occurrence.changes`, in the provider payload vocabulary,
  are written into the occurrence's override `VEVENT` (see
  `ICalBuilder.Series.put_override/5`), which is made from the master when
  the occurrence has none yet. The write is the one `delete_occurrence/4`
  makes: the cached document under its ETag, one re-read on a 412.

  Returns `{:ok, %{document: String.t()}}` with the document now on the
  server, `{:error, :not_found}` when the series is gone, or
  `{:error, reason}`, including the refusals of `Series.put_override/5`, which
  are answered before anything is written.
  """
  @spec update_occurrence(Base.client(), String.t() | nil, occurrence(), keyword()) ::
          {:ok, %{document: String.t()}} | {:error, term()}
  defdelegate update_occurrence(client, calendar_path, occurrence, opts), to: SeriesWrites

  @doc """
  Edits every occurrence of the series stored in the resource at
  `occurrence.href`, from the edit of the one `occurrence.key` names:
  `occurrence.changes` are written to the master `VEVENT`, and a move of the
  occurrence moves the whole series, its exceptions and overrides with it
  (see `ICalBuilder.Series.edit_master/5`). The write is the one
  `delete_occurrence/4` makes: the cached document under its ETag, one
  re-read on a 412.

  Returns `{:ok, %{document: String.t()}}` with the document now on the
  server, `{:error, :not_found}` when the series is gone, or
  `{:error, reason}`, including the refusals of `Series.edit_master/5`, which
  are answered before anything is written.
  """
  @spec update_series(Base.client(), String.t() | nil, occurrence(), keyword()) ::
          {:ok, %{document: String.t()}} | {:error, term()}
  defdelegate update_series(client, calendar_path, occurrence, opts), to: SeriesWrites

  @doc """
  Edits the occurrence `occurrence.key` names and every one after it, by
  splitting the series stored at `occurrence.href` in two there (see
  `ICalBuilder.Series.split/5`): `occurrence.changes` apply to the second
  half only.

  The second half, the tail, is created first, as a new resource beside the
  series in the same collection (`<collection><tail uid>.ics`, under
  `If-None-Match: *`); a tail that cannot be created leaves the series as it
  was. The series' own resource is then ended before the occurrence, under
  `If-Match`: the cached document under its ETag, else the server's copy.
  On a 412 the tail is deleted and the whole split made again, once, from a
  re-read of the server's copy, so both halves carry what changed there
  meanwhile. If the series still cannot be ended, the tail is deleted again
  and the failure reported, so the series is never left showing its
  following occurrences twice.

  An occurrence the rule makes nothing before is the series' first, and the
  edit is written as `update_series/4` writes it.

  Returns `{:ok, %{document: head, tail: %{uid:, href:, document:}}}` with
  the documents now on the server, `{:ok, %{document: document}}` for an
  edit of the first occurrence, `{:error, :not_found}` when the series is
  gone, or `{:error, reason}`, including the refusals of `Series.split/5`,
  which are answered before anything is written.
  """
  @spec split_series(Base.client(), String.t() | nil, occurrence(), keyword()) ::
          {:ok, %{document: String.t(), tail: SeriesWrites.tail()}}
          | {:ok, %{document: String.t()}}
          | {:error, term()}
  defdelegate split_series(client, calendar_path, occurrence, opts), to: SeriesWrites

  @doc """
  Fetches one event resource: `href` when known, otherwise the resource
  Tymeslot writes for `uid` in `calendar_path`. Returns the parsed events as a
  calendar-query would, or `{:error, :not_found}` when the server answers 404
  or 410.

  One resource holds one event, but a recurring one is a master VEVENT plus a
  VEVENT per modified occurrence, so this answers with a list. A caller asking
  "is this event over" has to see every occurrence to answer it; taking only
  the first would judge a whole series by its master.
  """
  @spec fetch_calendar_event(Base.client(), String.t() | nil, String.t() | nil, String.t() | nil) ::
          {:ok, [map()]} | {:error, :not_found} | {:error, term()}
  def fetch_calendar_event(client, calendar_path, uid, href) do
    with {:ok, url} <- event_url(client, calendar_path, uid, href) do
      # A missing resource is a per-event answer, not a host outage, so it
      # travels back through the breaker as a success and becomes an error
      # again out here.
      result =
        with_events_breaker(client, [], fn -> get_event_resource(client, url, href) end)

      case result do
        {:ok, :not_found} -> {:error, :not_found}
        other -> other
      end
    end
  end

  @doc """
  Looks up one event by its iCalendar UID in `calendar_path`, whatever the
  name of the resource that holds it: a calendar client that moves or writes
  an event need not name it after its UID. Answers as
  `fetch_calendar_event/4` does, `{:error, :not_found}` when no resource of
  the calendar holds the event or the calendar itself is gone.
  """
  @spec find_calendar_event(Base.client(), String.t(), String.t()) ::
          {:ok, [map()]} | {:error, :not_found} | {:error, term()}
  def find_calendar_event(client, calendar_path, uid) do
    url = UrlBuilder.build_calendar_url(client.base_url, calendar_path)

    # As in `fetch_calendar_event/4`, a missing calendar travels back through
    # the breaker as a success.
    result =
      with_events_breaker(client, [], fn ->
        case Http.report(url, client.username, client.password, XmlHandler.build_uid_query(uid)) do
          {:ok, %Req.Response{body: body}} -> XmlHandler.parse_calendar_query(body)
          {:error, reason} when reason in [:not_found, :gone] -> {:ok, []}
          {:error, reason} -> {:error, reason}
        end
      end)

    case result do
      {:ok, events} ->
        case Enum.filter(events, &(&1.uid == uid)) do
          [] -> {:error, :not_found}
          found -> {:ok, found}
        end

      error ->
        error
    end
  end

  defp get_event_resource(client, url, href) do
    case Http.get_event(url, client.username, client.password) do
      {:ok, %Req.Response{body: body, headers: headers}} ->
        parse_fetched_event(body, href || url, headers)

      {:error, reason} when reason in [:not_found, :gone] ->
        {:ok, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_fetched_event(body, href, headers) do
    case EventProcessor.parse_ical_events(body) do
      {:ok, events} ->
        etag = headers |> Map.new() |> Map.get("etag") |> List.wrap() |> List.first()
        stamp = %{href: href, etag: EventProcessor.clean_etag(etag), raw_ical: body}

        # The href, ETag and document belong to the resource, so every VEVENT
        # parsed out of it carries the same three.
        {:ok, Enum.map(events, &Map.merge(&1, stamp))}

      {:error, reason} ->
        {:error, {:unparseable_event, reason}}
    end
  end

  # Every event URL in this module resolves through `UrlBuilder`, which knows
  # that a server-supplied href is server-root-relative and must therefore be
  # joined to the base *origin*, never appended to a `base_url` that already
  # carries the same DAV path.
  defp event_url(client, calendar_path, uid, href),
    do: UrlBuilder.resolve_event_url(client.base_url, calendar_path, uid, href)

  defp with_events_breaker(client, opts, fun) when is_function(fun, 0) do
    provider = Map.get(client, :provider, :caldav)
    host = Base.extract_host_from_url(client.base_url)
    opts = Keyword.put(opts, :host, host)
    CalendarCircuitBreaker.with_breaker(provider, opts, fun)
  end
end
