defmodule Tymeslot.Integrations.Calendar.CalDAV.Events do
  @moduledoc """
  CalDAV event operations domain.

  Owns the full lifecycle of calendar event CRUD:

  - **ETag-conditional updates**: callers pass the cached ETag via `:etag`
    in `opts` for a direct conditional PUT with `If-Match`. When no cached
    ETag is available, the module falls back to a HEAD probe, and finally
    to `If-Match: *` if HEAD also fails. Prevents lost updates on
    concurrent edits.
  - **Conflict resolution policy**: on `412 Precondition Failed`, the
    caller chooses one of `:fail | :keep_server | :keep_local` via
    `:conflict_resolution` in `opts`. See `ConflictResolution` for the
    semantics of each value. A server that answers a conditional PUT with
    `409` instead of `412` follows the same policy when a real ETag was
    sent; when only `If-Match: *` was sent the write is simply replayed
    unconditionally, since that condition guarded nothing.
  - **iCal construction**: builds valid RFC 5545 event payloads from domain maps.
  - **Per-operation retry policies**: reads retry on transient failures.
  - **Circuit breaker protection** for all operations.

  Callers receive parsed domain types — never raw HTTP responses, XML, or iCal.
  """

  alias Tymeslot.Infrastructure.{CalendarCircuitBreaker, RetryLogic}

  alias Tymeslot.Integrations.Calendar.CalDAV.{
    Base,
    ConflictResolution,
    EventProcessor,
    Http,
    Scheduling,
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
  # a HEAD probe and then to `If-Match: *` exactly as it did before.
  defp created_event(uid, calendar_path, url, headers) do
    CreatedEvent.new(uid,
      provider_event_id: href_path(url),
      calendar_id: calendar_path,
      etag: EventProcessor.clean_etag(etag_from_headers(headers))
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
  HEAD probe, and finally to `If-Match: *` if HEAD also fails.

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

    case do_conditional_put(client, url, ical_data, etag, :fail, opts) do
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
    case fetch_event_document(client, url, opts) do
      {:ok, raw_ical, etag} ->
        ical_data = document_to_put(client, raw_ical, uid, event_data)
        do_conditional_put(client, url, ical_data, etag, policy, opts)

      {:error, :not_found} ->
        rebuild_and_put(client, url, uid, event_data, policy, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rebuild_and_put(client, url, uid, event_data, policy, opts) do
    ical_data = rebuild_document(client, uid, event_data)
    do_conditional_put(client, url, ical_data, resolve_etag(url, client, opts), policy, opts)
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

  defp fetch_event_document(client, url, opts) do
    get_opts = Keyword.put(opts, :timeout, Keyword.get(opts, :read_timeout, 30_000))

    case Http.get_event(url, client.username, client.password, get_opts) do
      {:ok, %Req.Response{body: body, headers: headers}} when is_binary(body) and body != "" ->
        {:ok, body, etag_from_headers(headers)}

      # A 200 with nothing in it describes no event, so there is nothing to
      # preserve: treat it as the absent resource it looks like.
      {:ok, %Req.Response{}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
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
          etag = resolve_etag(url, client, opts)

          do_conditional_put(client, url, ical_data, etag, policy, opts)
        end
      end)
    else
      {:error, :invalid_conflict_resolution_policy}
    end
  end

  defp do_conditional_put(client, url, ical_data, etag, policy, opts) do
    base_put_opts =
      if etag, do: [operation: :update, if_match: etag], else: [operation: :update]

    put_opts = Keyword.merge(base_put_opts, Keyword.take(opts, [:timeout]))

    put_fun = fn ->
      Http.put_event(url, client.username, client.password, ical_data, put_opts)
    end

    # If-Match PUTs (with a specific ETag or with *) are safe to retry: the
    # server will either apply the write or reject it with 412. The
    # duplicate-creation risk only applies to If-None-Match: * creates, which
    # go through put_ical/5, not this function. So we always apply retry here,
    # regardless of whether we have a specific ETag or fell back to If-Match: *.
    retry_opts = Keyword.get(opts, :retry_opts, Base.default_retry_opts())
    raw_result = RetryLogic.with_retry(put_fun, retry_opts)

    case raw_result do
      {:ok, %Req.Response{status: status}} when status in [200, 201, 204] ->
        :ok

      # With no ETag all we sent was `If-Match: *`, which asserts nothing but
      # that the resource exists (RFC 7232 §3.1). A 412 against it therefore
      # means the event is absent from the server, not that someone else
      # changed it — so report it as such. `CalendarEventSync` recreates a
      # missing event on `:not_found`, whereas none of the conflict policies
      # can: each assumes a server copy to reconcile against. Without this a
      # booking whose event never landed (or was deleted in the organiser's
      # client) could never be restored — every later update re-sent the same
      # doomed conditional PUT and the calendar stayed empty.
      {:error, :precondition_failed} when is_nil(etag) ->
        Logger.info("CalDAV event absent on conditional update, reporting as not found")
        {:error, :not_found}

      {:error, :precondition_failed} ->
        handle_precondition_failed(client, url, ical_data, policy, opts)

      # The server rejected the conditional PUT with a 409. When all we sent
      # was `If-Match: *` there was no ETag and therefore no lost-update
      # protection to preserve — the condition asserted only that the event
      # exists — so replaying it unconditionally loses nothing and gets the
      # write through on servers that mishandle the conditional form.
      {:error, :conditional_not_supported} when is_nil(etag) ->
        Logger.warning("CalDAV server rejected If-Match: *, retrying unconditionally")
        force_put(client, url, ical_data, opts)

      # With a real ETag the condition did carry a guarantee, so treat the 409
      # as the precondition failure the server meant it to be and let the
      # configured policy decide.
      {:error, :conditional_not_supported} ->
        handle_precondition_failed(client, url, ical_data, policy, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # :fail — surface the conflict to the caller.
  defp handle_precondition_failed(_client, _url, _ical, :fail, _opts),
    do: {:error, :precondition_failed}

  # :keep_server — silently accept the server's version; next sync will
  # refresh the local cache.
  defp handle_precondition_failed(_client, _url, _ical, :keep_server, _opts),
    do: :ok

  # :keep_local — force-overwrite by repeating the PUT unconditionally.
  defp handle_precondition_failed(client, url, ical_data, :keep_local, opts),
    do: force_put(client, url, ical_data, opts)

  # An overwrite carrying no conditional header at all. `If-Match: *` is not a
  # substitute: it still asserts the resource exists, so a server is entitled
  # to refuse it.
  defp force_put(client, url, ical_data, opts) do
    put_opts = Keyword.merge([operation: :force_update], Keyword.take(opts, [:timeout]))

    case Http.put_event(url, client.username, client.password, ical_data, put_opts) do
      {:ok, %Req.Response{status: status}} when status in [200, 201, 204] ->
        :ok

      {:error, reason} ->
        {:error, reason}
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

  # Prefer the caller-supplied ETag (cached on provider_calendar_events.etag).
  # Fall back to a HEAD probe only when the caller does not know the current
  # ETag — typically for legacy paths or ad-hoc scripts.
  defp resolve_etag(url, client, opts) do
    case Keyword.get(opts, :etag) do
      etag when is_binary(etag) and etag != "" -> etag
      _missing -> fetch_current_etag(url, client, opts)
    end
  end

  # HEAD → extract ETag for conditional PUT. Short timeout since ETag is optional:
  # if HEAD times out we proceed without it rather than failing the entire update.
  defp fetch_current_etag(url, client, opts) do
    head_timeout = Keyword.get(opts, :head_timeout, 15_000)
    head_opts = Keyword.put(opts, :timeout, head_timeout)

    case Http.head_event(url, client.username, client.password, head_opts) do
      {:ok, %{headers: headers}} -> etag_from_headers(headers)
      _error -> nil
    end
  end

  defp etag_from_headers(headers) do
    case Map.get(headers, "etag") do
      [etag | _rest] -> etag
      _other -> nil
    end
  end

  defp with_events_breaker(client, opts, fun) when is_function(fun, 0) do
    provider = Map.get(client, :provider, :caldav)
    host = Base.extract_host_from_url(client.base_url)
    opts = Keyword.put(opts, :host, host)
    CalendarCircuitBreaker.with_breaker(provider, opts, fun)
  end
end
