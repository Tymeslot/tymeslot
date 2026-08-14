defmodule Tymeslot.Integrations.Calendar.SyncLink.RecurringSeries do
  @moduledoc """
  Answers the one question a recurring source cannot answer about itself: what
  rule describes the whole series?

  ## Why the cached rule is not that answer

  `GoogleCalendarApi.list_events/4` sends `singleEvents=true`, so Google expands
  a series before Tymeslot ever sees it and returns one item per occurrence.
  Every one of those items carries the same `iCalUID`, which the normaliser maps
  to `uid`, and the cache is unique on `{calendar_integration_id, uid}` with
  `upsert_batch/1` keeping the last entry. Ordered by start time, the survivor
  is the **final occurrence**.

  So the row a recurring source is read from is an instance, holding the last
  occurrence's times, and its `recurrence_rule` is whatever that instance
  happened to carry rather than a description of the series. Building a mirror
  from it places a single busy block at the last occurrence's date — a meeting
  that recurs every Tuesday until December shows up once, in December, and the
  organiser's Tuesdays are all bookable.

  ## Why a skip is the only alternative to the master

  Both failures here answer `:skip`, and neither falls back to the cached rule.
  That is the whole design. A skip leaves no placeholder, which the reconcile
  sweep notices and retries, and which an organiser reads as "this has not
  synced yet". A guess leaves a placeholder that is confidently wrong, which
  nothing retries and which an organiser reads as the truth. The first failure
  is recoverable and the second is not, so the cheap-looking fallback is the
  expensive one.

  The skips are:

  - **No `recurring_event_id`.** Nothing to fetch the master with. Google
    populates `recurringEventId` on every expanded instance, so its absence
    means either the source is not really an instance or the row predates the
    column being read — in both cases the series cannot be described.
  - **The master fetch failed.** A rate limit, an expired token, a master
    deleted between the sync and the mirror. Retrying belongs to the sweep,
    which already exists for exactly the mirrors that are missing.
  - **The master carries no RRULE.** The id pointed at something that is not a
    series master. Mirroring it with an empty rule would write a plain one-off
    block at the last occurrence's time — the same wrong answer as the cached
    rule, reached by a different route.
  - **No source integration to ask.** A link whose `source_integration` was
    never preloaded has no token and no provider, so there is nothing to make
    the call with. `CalendarSyncLinkQueries.get/1` preloads it and every
    production caller goes through that, which makes this a caller bug rather
    than a runtime condition — and it is answered rather than raised because
    a `FunctionClauseError` inside a sync job is a worse report of that bug
    than a skip and a log line.

  ## The request cost

  One `get_event/3` per recurring series per change — not one per occurrence,
  which is the cost that would have made this unaffordable. A weekly series
  running for a year is one cache row, one master fetch, one placeholder and one
  mirror row, whether it has fifty occurrences or five thousand. Non-recurring
  sources answer `:not_recurring` without touching the provider at all, so the
  ordinary event pays nothing for this module existing.

  ## Why the raw provider body rather than a `CalendarEvent`

  The master's `recurrence` is a **list**: an RRULE, and then any number of
  EXDATE, RDATE or EXRULE lines. `EventNormaliser.map_recurrence_rule/1` keeps
  only the first entry, so a normalised master would arrive with its exceptions
  already discarded — and the exceptions are precisely what the placeholder
  needs in order to stop blocking a cancelled occurrence. Reading the list here
  is what keeps them.

  The normalised `recurrence_exceptions` field is no substitute either, and not
  only because the master is never normalised on this path: it is a `[Date.t()]`,
  which cannot express an exception at a given time in a given zone. A weekly
  09:00 meeting with one Tuesday cancelled needs the instant, not the day.

  ## Google only, and why that is not a `Capability` question

  `Capability`'s `:recurrence` describes what a **target** can be handed.
  This is the **source** side, and the two are independent: the target must
  expand a series it receives, while the source must be able to produce the
  series' rule. Google is the only provider with a single-event GET
  (`CalendarAPI.get_event/3`) reachable from here, so every other source
  skips — a recurring Outlook or CalDAV source is refused before it ever
  reaches this module, by `Eligibility`, but the clause here means adding a
  second source provider is a clause rather than a rediscovery.
  """

  require Logger

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.SyncLink.SeriesMasterCache

  @typedoc """
  A series as its master describes it.

  `recurrence_rule` is the RRULE line, prefix included, in the form the outbound
  mapper expects — `EventMapper.maybe_add_recurrence/2` strips and re-adds the
  prefix itself, so either form works and the master's own is kept.

  `exceptions` holds the master's EXDATE lines verbatim — whole iCalendar
  property lines, keeping whichever `TZID` or `VALUE=DATE` parameter the master
  wrote, because the instant an occurrence was cancelled at is in those
  parameters. They are written onto the placeholder alongside the rule, which is
  what stops a cancelled occurrence from going on blocking its slot.

  EXDATE only. `RDATE` adds occurrences the rule does not name and `EXRULE`
  removes a whole pattern; neither is a cancellation, and forwarding them
  unexamined would let the placeholder describe a series the source does not
  have. A *moved* occurrence is not here at all and cannot be — see the
  moduledoc's note on `singleEvents=true`.

  The timing keys are the master's own start and end, and they are not
  decoration. A rule says "and then every week" without saying when the first
  occurrence falls; that is DTSTART's job, and taking it from the cached row
  instead pairs the master's rule with an expanded instance's start — the last
  one — describing a series that begins where the real one ends. They mirror
  `ProviderCalendarEventSchema`'s own split so the payload builder reads them
  exactly as it reads a source event, and `all_day` is `nil` when the master's
  timing could not be read at all, which the caller treats as "no series to
  describe" rather than defaulting either way.
  """
  @type series :: %{
          recurrence_rule: String.t(),
          exceptions: [String.t()],
          all_day: boolean() | nil,
          start_at: DateTime.t() | nil,
          end_at: DateTime.t() | nil,
          start_date: Date.t() | nil,
          end_date: Date.t() | nil
        }

  @typedoc """
  Why no series could be described. Every one of these means "write no
  placeholder", never "write one from the cached rule".
  """
  @type skip_reason ::
          :no_series_master
          | :master_fetch_failed
          | :master_has_no_recurrence_rule
          | :provider_has_no_series_lookup
          | :source_integration_unknown

  @doc """
  Resolves the series a recurring source belongs to.

  `:not_recurring` for an ordinary event, which is the common case and costs no
  request. `{:ok, series}` when the master was fetched and carries a rule.
  `{:skip, reason}` in every other case — see the moduledoc for why the cached
  rule is never the fallback.
  """
  @spec resolve(map(), CalendarIntegrationSchema.t() | any()) ::
          :not_recurring | {:ok, series()} | {:skip, skip_reason()}
  def resolve(source, integration) do
    cond do
      not recurring?(source) ->
        :not_recurring

      not is_struct(integration, CalendarIntegrationSchema) ->
        {:skip, :source_integration_unknown}

      true ->
        fetch_series(source, integration)
    end
  end

  defp recurring?(%{recurrence_rule: rule}) when is_binary(rule) and rule != "", do: true
  defp recurring?(_source), do: false

  # The master handle. Its absence is the skip that matters most: the cached
  # rule sits right there on the row and looks like a usable answer, and using
  # it is the failure this whole module exists to prevent.
  defp fetch_series(%{recurring_event_id: master_id} = source, integration)
       when is_binary(master_id) and master_id != "" do
    case api_module(integration) do
      nil ->
        {:skip, :provider_has_no_series_lookup}

      api ->
        request_master(api, integration, calendar_id(source, integration), master_id)
    end
  end

  defp fetch_series(_source, _integration), do: {:skip, :no_series_master}

  defp request_master(api, integration, calendar_id, master_id) do
    case cached_master(api, integration, calendar_id, master_id) do
      {:ok, master} ->
        read_recurrence(master, master_id)

      error ->
        # Logged rather than surfaced: the caller's answer is "no placeholder
        # this pass", and the reconcile sweep is what turns that into a retry.
        # Without this line a series that never mirrors leaves no trace at all.
        Logger.warning("Series master fetch failed; skipping the mirror for this pass",
          calendar_integration_id: integration.id,
          recurring_event_id: master_id,
          reason: inspect(error)
        )

        {:skip, :master_fetch_failed}
    end
  end

  # One master, however many links mirror the series onto however many
  # calendars. The fan-out is per link — the sync path enqueues a job each — so
  # a calendar with fifty series on three links asks for a hundred and fifty
  # masters where fifty distinct ones exist, every sweep, against the quota the
  # user-facing paths share.
  #
  # Those jobs run *together*, which is why the cache has to coalesce rather
  # than merely store: without it every duplicate misses, fetches, and stores
  # the same answer before any of them has written it. `get_or_compute/3` holds
  # the concurrent callers on the first request.
  #
  # Only `{:ok, _}` is retained: `cache_errors: false` is what keeps a failed
  # fetch out of the table. A failure means "no placeholder this pass", and
  # storing it would turn one provider hiccup into two minutes of skipped
  # mirrors across every link. `CacheStore` reads that from the `{:error, _}`
  # shape, which is the shape `get_event/3` already answers with.
  defp cached_master(api, integration, calendar_id, master_id) do
    SeriesMasterCache.get_or_compute(
      {integration.id, master_id},
      fn -> api.get_event(integration, calendar_id, master_id) end,
      :timer.minutes(2),
      cache_errors: false
    )
  end

  # Google sends `recurrence` as a list of iCalendar property lines in no
  # guaranteed order, so the RRULE is found by prefix rather than by position.
  # A master with no RRULE is not a series master — most likely the id pointed
  # at a single event — and is skipped rather than mirrored with an empty rule,
  # which would write a plain one-off block at the last occurrence's time: the
  # same wrong answer, arrived at by a different route.
  defp read_recurrence(master, master_id) do
    lines = List.wrap(Map.get(master, "recurrence"))

    case Enum.find(lines, &String.starts_with?(&1, "RRULE")) do
      nil ->
        Logger.warning("Series master carries no RRULE; skipping the mirror",
          recurring_event_id: master_id
        )

        {:skip, :master_has_no_recurrence_rule}

      rrule ->
        {:ok,
         Map.merge(
           %{
             recurrence_rule: rrule,
             exceptions: Enum.filter(lines, &String.starts_with?(&1, "EXDATE"))
           },
           timing(master)
         )}
    end
  end

  # The master's own start and end, and they are not optional decoration.
  #
  # A recurrence rule says "and then every week"; it says nothing about when the
  # first occurrence is. That comes from DTSTART, and pairing the master's rule
  # with the *cached row's* start is the failure this module was written to
  # prevent, arrived at one step later. Under `singleEvents=true` the row is an
  # expanded instance and `upsert_batch/1` keeps the last of them, so a series
  # running since March is cached as its December occurrence: "every Tuesday
  # from December, forever" leaves every real occurrence unblocked and blocks
  # every date after the series ends.
  #
  # It is also what makes the EXDATEs mean anything. RFC 5545 matches an EXDATE
  # against the occurrences DTSTART generates, so a cancellation lands only when
  # both come from the same event. Carried from different events they exclude
  # nothing, and a cancelled occurrence goes on blocking time while appearing to
  # have been handled.
  #
  # `nil` on either side is left for the caller to notice rather than defaulted:
  # a master whose timing cannot be read is not a series anyone can describe.
  defp timing(master) do
    case {parse_point(Map.get(master, "start")), parse_point(Map.get(master, "end"))} do
      {%Date{} = start_date, %Date{} = end_date} ->
        %{all_day: true, start_at: nil, end_at: nil, start_date: start_date, end_date: end_date}

      {%DateTime{} = start_at, %DateTime{} = end_at} ->
        %{all_day: false, start_at: start_at, end_at: end_at, start_date: nil, end_date: nil}

      _unreadable ->
        %{all_day: nil, start_at: nil, end_at: nil, start_date: nil, end_date: nil}
    end
  end

  # The two shapes Google uses, and nothing else. A malformed value answers nil
  # rather than raising: this runs inside a sync job, where a raise is a crashed
  # worker and a nil is a skipped mirror the sweep retries.
  defp parse_point(%{"dateTime" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> DateTime.shift_zone!(at, "Etc/UTC")
      _error -> nil
    end
  end

  defp parse_point(%{"date" => value}) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _error -> nil
    end
  end

  defp parse_point(_other), do: nil

  # The calendar the *instance* was synced from, first. One integration can
  # cover several Google calendars, and the master lives on the same one its
  # instances do — asking the integration's booking calendar instead would look
  # for it on the wrong calendar and get a 404 for an event that is plainly
  # there. The remaining two are the fallbacks every other Google call in this
  # codebase uses, in the same order.
  defp calendar_id(%{provider_calendar_id: id}, _integration) when is_binary(id) and id != "",
    do: id

  defp calendar_id(_source, integration),
    do: integration.default_booking_calendar_id || "primary"

  # Resolved from the *integration*, not the cached row's `provider` string: the
  # integration is what the API client is handed and what holds the token, and a
  # row whose provider disagreed with its integration's would otherwise pick a
  # client that cannot authenticate against it.
  defp api_module(%CalendarIntegrationSchema{provider: provider})
       when provider in [:google, "google"],
       do: Config.google_calendar_api_module()

  defp api_module(_integration), do: nil
end
