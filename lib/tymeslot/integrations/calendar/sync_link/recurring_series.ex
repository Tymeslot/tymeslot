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

  ## Why the cached rule is not even the question

  What an expanded instance carries is *no rule at all*. Google puts the
  `recurrence` array on the master alone, so an instance has no such key, and
  `EventNormaliser.map_recurrence_rule/1` maps `nil` onto every Google row in
  the cache. A `recurrence_rule` on a Google row is not the wrong description of
  a series; it is a value that does not occur.

  That is why `recurring?/1` reads `recurring_event_id` instead. It is the only
  field an instance carries that names the series it belongs to, it is present
  on every occurrence of every series, and it is the handle the master fetch
  needs regardless — so the question and the answer are the same value rather
  than two that live data never presents together. Asking the rule instead
  answered "not recurring" for every row that has ever existed, which meant the
  entire master fetch below was unreachable and every series was mirrored as the
  one-off block the section above describes.

  ## Why a skip is the only alternative to the master

  Both failures here answer `:skip`, and neither falls back to the cached rule.
  That is the whole design. A skip leaves no placeholder, which the reconcile
  sweep notices and retries, and which an organiser reads as "this has not
  synced yet". A guess leaves a placeholder that is confidently wrong, which
  nothing retries and which an organiser reads as the truth. The first failure
  is recoverable and the second is not, so the cheap-looking fallback is the
  expensive one.

  The skips are:

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
  - **No `recurring_event_id`.** Kept as a clause but not reachable through
    `resolve/2`, which now refuses such a source as `:not_recurring` before the
    fetch is attempted — the id is what recurrence is read from, so a source
    without one never gets this far. It stands for a caller that reaches
    `fetch_series/2` some other way, and for the same reason as the clause
    above: a skip reports that better than a raise.

  ## The one answer that is not a skip: a deleted series

  A master whose series has been deleted does **not** fail the fetch. Measured
  on the live API: Google answers `get_event` for a deleted master with a full
  body, `recurrence` array intact, and only `status` changed to `"cancelled"`.
  The fetch succeeds, the rule reads fine, and the mirror is rewritten from a
  series that no longer exists — which is how a deleted series' placeholder went
  on blocking availability indefinitely.

  That case answers `:series_deleted`, and it is deliberately not a skip. A skip
  means "no placeholder this pass" and leaves the existing one standing for the
  sweep to retry; a deleted series means the placeholder must come down. The
  caller turns it into a withdrawal.

  The check reads Google's `status` and therefore lives in the Google-side
  reader. Graph spells the same fact as a boolean `isCancelled` and has no
  `status` key, so a check hoisted into `resolve/2` would read `nil` for every
  Outlook master and never fire; the CalDAV family expands series locally, never
  sets `recurring_event_id`, and so never reaches this module at all.

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

  ## Two providers, two master shapes, and one that needs no master

  Google and Outlook both need the fetch, for the same structural reason: each
  is synced through a path that expands a series before it is cached —
  `singleEvents=true` for Google, `calendarView` for Outlook — so the cached row
  is an occurrence carrying the master's id and no rule.

  What they do not share is the master's shape, which is why `read_recurrence/3`
  dispatches on the provider rather than generalising. Google answers a list of
  whole iCalendar property lines: an RRULE, and any EXDATEs beside it. Graph
  answers a structured `recurrence` object of a `pattern` and a `range`, which
  is converted back through `RecurrenceConverter.outlook_to_rrule/1` — the same
  converter the inbound normaliser uses, so a series described through this path
  and one described through an ordinary sync agree.

  Graph also carries **no exceptions on the master**: a cancelled occurrence is
  a separate `exception`-type event rather than an EXDATE line, and
  `calendarView` does not return it beside the master. So an Outlook series
  resolves with an empty exception list, and a cancelled Outlook occurrence goes
  on blocking its slot on the target until that is built. It is a bounded wrong
  — one occurrence, not a whole series at the wrong date — and it is recorded
  here rather than left for a reader to discover from an empty list.

  **The CalDAV family needs no master at all**, and that is a finding rather
  than unfinished work. `ICalNormaliser` expands a CalDAV series locally:
  `expand_event/3` emits one raw map per occurrence, `build_uid/1` gives each
  occurrence its own uid — so `upsert_batch/1` never collapses the series into
  one row the way it does for the other two — and `resolve_timing/1` times each
  row from its own occurrence rather than from the master's DTSTART. Every
  cached CalDAV row is therefore already the correctly-timed one-off this module
  would otherwise have to reconstruct, and the ordinary mirror path handles it
  without ever reaching here. `recurring_event_id` is never set anywhere in the
  CalDAV or iCal paths, so no such row can.

  The one thing to be careful of is that a CalDAV row *does* carry a
  `recurrence_rule` — `build_calendar_event/3` copies the master's onto every
  occurrence. A rule on a CalDAV row therefore does not mean the row describes a
  series, and passing it through to a placeholder would write a whole series
  starting at that occurrence, once per occurrence.

  ## Which `Capability` question this is

  `Capability` holds both ends, as two rows rather than one. `:recurrence`
  describes what a **target** can be handed; `:series_lookup` describes what a
  **source** can have fetched from it, which is this module's question. The two
  are independent — the target must expand a series it receives, while the
  source must be able to produce the series' rule — and they no longer name the
  same providers: the source side admits Google and Outlook, while the target
  side remains Google's alone, because only Google's outbound mapper carries the
  EXDATE lines a series' cancellations live in.

  `api_module/1` reads `:series_lookup` rather than matching providers itself,
  so adding a second source provider is one cell in that table rather than a
  clause here plus a rediscovery of everywhere else the fact is stated.

  This section previously claimed that `Eligibility` refuses a recurring
  Outlook or CalDAV source before it reaches this module. **It did not**, and
  the gap was a silent data-loss path rather than a documentation error.
  `Eligibility.recurrence_supported?/2` asked only whether the *target* could
  expand a series, so an Outlook or CalDAV source pointed at a Google target
  passed the gate, arrived here, and left with
  `{:skip, :provider_has_no_series_lookup}`. The write-back worker read that as
  an ineligible source and discarded the job: no placeholder was ever written,
  nothing retried, and the organiser's recurring meetings went on being
  bookable over with no indication anywhere that they were unmirrored.

  The gate now asks both ends, so the claim is true — but the refusal it makes
  is recorded and rendered rather than merely silent, because a link that
  cannot mirror is something the organiser has to be told about.
  """

  require Logger

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Outlook.RecurrenceConverter
  alias Tymeslot.Integrations.Calendar.SyncLink.Capability
  alias Tymeslot.Integrations.Calendar.SyncLink.SeriesMasterCache

  @typedoc """
  A series as its master describes it.

  `recurrence_rule` is the RRULE line, prefix included, in the form the outbound
  mapper expects — `EventMapper.maybe_add_recurrence/2` strips and re-adds the
  prefix itself, so either form works and the master's own is kept.

  `exceptions` holds the master's EXDATE lines verbatim — whole iCalendar
  property lines, keeping whichever `TZID` or `VALUE=DATE` parameter the master
  wrote, because the instant an occurrence was cancelled at is in those
  parameters. They are written onto the placeholder alongside the rule.

  **This is not where a Google cancellation is found**, and believing it was
  cost a live defect. Cancelling one occurrence through Google's own UI leaves
  the master's `recurrence` array untouched: the series measured on the
  organiser's calendar, with an occurrence genuinely cancelled, answered
  `["RRULE:FREQ=WEEKLY;COUNT=5"]` and nothing else. Google records the
  cancellation on the *instance* — a separate exception event carrying
  `status: "cancelled"` — so this list is empty for exactly the case it was
  thought to cover. A master imported from elsewhere may still carry EXDATEs,
  which is why they are still forwarded; they are simply not what a cancellation
  on Google produces. `SyncLink.MovedOccurrence` reads the instance instead.

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
  `:series_deleted` when the master was fetched and says the series is gone —
  a withdrawal, not a skip; see the moduledoc. `{:skip, reason}` in every other
  case — see the moduledoc for why the cached rule is never the fallback.
  """
  @spec resolve(map(), CalendarIntegrationSchema.t() | any()) ::
          :not_recurring | {:ok, series()} | :series_deleted | {:skip, skip_reason()}
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

  # Recurrence is read from the master handle, not from the cached rule, and the
  # difference is the whole module. Under `singleEvents=true` the row is an
  # expanded instance, an instance carries no `recurrence` array — only the
  # master does — and `EventNormaliser.map_recurrence_rule/1` therefore maps
  # `nil` onto every Google row there is. Gating on the rule asked a question
  # whose answer was always "no", so no series ever reached the master fetch and
  # every one was mirrored as a plain one-off block at the last occurrence's
  # date: exactly the failure the moduledoc above describes, reached by never
  # running the code that prevents it.
  #
  # `recurringEventId` is what an instance does carry, on every occurrence of
  # every series, and it is the same field `fetch_series/2` needs anyway. Asking
  # for it here means the question and the handle are one value rather than two
  # that live data never presents together.
  defp recurring?(%{recurring_event_id: id}) when is_binary(id) and id != "", do: true
  defp recurring?(_source), do: false

  # The same handle, re-matched. A source that reaches here has one by the guard
  # above, so the fallback below is the answer to a caller that has bypassed
  # `resolve/2` rather than to a live row — kept because the two clauses are
  # separately reachable and a `FunctionClauseError` inside a sync job is a worse
  # report of that than a skip.
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
        read_recurrence(master, master_id, integration.provider)

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

  # The two providers describe a series in shapes that share no structure, so
  # this dispatches rather than generalising. A single reader would have to
  # branch on the value's type to tell a list of iCalendar lines from a
  # `pattern`/`range` map, which is the same dispatch written less legibly and
  # with the provider — the thing that actually decides — left implicit.
  defp read_recurrence(master, master_id, provider) when provider in [:outlook, "outlook"],
    do: read_graph_recurrence(master, master_id)

  defp read_recurrence(master, master_id, _provider),
    do: read_ical_recurrence(master, master_id)

  # Google sends `recurrence` as a list of iCalendar property lines in no
  # guaranteed order, so the RRULE is found by prefix rather than by position.
  # A master with no RRULE is not a series master — most likely the id pointed
  # at a single event — and is skipped rather than mirrored with an empty rule,
  # which would write a plain one-off block at the last occurrence's time: the
  # same wrong answer, arrived at by a different route.
  # A deleted series answers this fetch rather than 404ing, and that is the
  # whole reason the deletion went undetected for so long. Measured on the live
  # API: deleting a `FREQ=WEEKLY;COUNT=3` master and then asking `get_event` for
  # it returns a full 19-key body with its `recurrence` array **intact** and
  # `status` flipped to `"cancelled"`. Nothing else changes — the rule, the
  # timing and the iCalUID are all still there.
  #
  # So a cancelled master is indistinguishable from a live one to every reader
  # that looks only at `recurrence`, which is what this function used to be, and
  # the engine happily rewrote a placeholder from a series the organiser had
  # deleted. The earlier reading of this defect assumed the fetch 404s and would
  # have keyed a fix on `:master_fetch_failed`, a branch a deleted series never
  # reaches; the status is the discriminator that actually fires, and it costs
  # no extra call because the body is already here.
  #
  # It answers `:series_deleted` rather than a skip because the two mean
  # opposite things to the caller. A skip is "no placeholder this pass", which
  # leaves the existing one in place for the sweep to retry — exactly wrong for
  # a series that is gone, whose placeholder must come down. See the moduledoc.
  #
  # This lives in the Google-side reader rather than in `resolve/2` because
  # `status` is Google's spelling. Graph marks a cancelled event with a boolean
  # `isCancelled` (`outlook/event_normaliser.ex:96`) and carries no `status`
  # key at all, so a shared check would read `nil` for every Outlook master and
  # silently never fire. The CalDAV family never arrives here: it expands series
  # locally and never sets `recurring_event_id`, so `recurring?/1` refuses it
  # first.
  defp read_ical_recurrence(%{"status" => "cancelled"}, master_id) do
    Logger.info("Series master reports the series deleted; withdrawing the mirror",
      recurring_event_id: master_id
    )

    :series_deleted
  end

  defp read_ical_recurrence(master, master_id) do
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

  # Graph does not speak RRULE. A master carries a structured `recurrence`
  # object — a `pattern` and a `range` — which `RecurrenceConverter` already
  # translates in both directions for the normaliser and the outbound mapper.
  # The read direction is reused here rather than reimplemented, so a series
  # arriving through the mirror path and one arriving through an ordinary sync
  # produce the same rule.
  #
  # `outlook_to_rrule/1` answers `nil` for a pattern outside its coverage —
  # Graph's `relativeMonthly`/`relativeYearly` forms — and that is treated as
  # the same skip as a master with no rule at all. It is the one that matters
  # most to get right: a `nil` rule reaching the payload writes a plain one-off
  # block at the series' first occurrence and leaves every later one bookable,
  # which is precisely the confidently-wrong placeholder nothing retries.
  #
  # There are no exception lines. Graph does not express a cancelled occurrence
  # on the master: it carries the deletion as a separate `exception`-type event
  # that `calendarView` never returns alongside the master. So the list is
  # empty rather than absent — the same shape the Google path produces for a
  # series with nothing cancelled — and a cancelled Outlook occurrence goes on
  # blocking its slot on the target until that is built. That is a known and
  # bounded wrong, unlike a whole series at the wrong date, and it is stated in
  # the moduledoc rather than left for a reader to discover.
  defp read_graph_recurrence(master, master_id) do
    with recurrence when is_map(recurrence) <- Map.get(master, "recurrence"),
         rrule when is_binary(rrule) and rrule != "" <-
           RecurrenceConverter.outlook_to_rrule(recurrence) do
      {:ok, Map.merge(%{recurrence_rule: rrule, exceptions: []}, graph_timing(master))}
    else
      _unreadable ->
        Logger.warning(
          "Series master carries no recurrence Graph can express; skipping the mirror",
          recurring_event_id: master_id
        )

        {:skip, :master_has_no_recurrence_rule}
    end
  end

  # Graph's own timing shape, which is not Google's. Every value is a
  # `%{"dateTime" => ..., "timeZone" => ...}` pair — there is no `"date"` key
  # even for an all-day event, which is marked by `isAllDay` and carries
  # midnight-to-midnight datetimes instead.
  #
  # The datetimes are also not ISO-8601 instants: Graph writes
  # `2026-03-03T09:00:00.0000000` with the zone in a sibling key, so they are
  # parsed against that zone rather than through `DateTime.from_iso8601/1`,
  # which would reject the value outright for having no offset.
  defp graph_timing(master) do
    all_day = Map.get(master, "isAllDay") == true

    case {parse_graph_point(Map.get(master, "start")), parse_graph_point(Map.get(master, "end"))} do
      {%DateTime{} = start_at, %DateTime{} = end_at} when all_day ->
        %{
          all_day: true,
          start_at: nil,
          end_at: nil,
          start_date: DateTime.to_date(start_at),
          end_date: DateTime.to_date(end_at)
        }

      {%DateTime{} = start_at, %DateTime{} = end_at} ->
        %{all_day: false, start_at: start_at, end_at: end_at, start_date: nil, end_date: nil}

      _unreadable ->
        %{all_day: nil, start_at: nil, end_at: nil, start_date: nil, end_date: nil}
    end
  end

  # A malformed value answers nil rather than raising, for the reason
  # `parse_point/1` does: this runs inside a sync job, where a raise is a
  # crashed worker and a nil is a skipped mirror the sweep retries.
  defp parse_graph_point(%{"dateTime" => value} = point) when is_binary(value) do
    zone = Map.get(point, "timeZone") || "Etc/UTC"

    with {:ok, naive} <- NaiveDateTime.from_iso8601(value),
         {:ok, at} <- DateTime.from_naive(naive, zone_name(zone)) do
      DateTime.shift_zone!(at, "Etc/UTC")
    else
      _error -> nil
    end
  end

  defp parse_graph_point(_other), do: nil

  # Graph answers `UTC` for a request carrying the `outlook.timezone="UTC"`
  # preference every read in this codebase sends, and that is not an IANA name
  # the datetime database knows. Anything else is passed through: Graph is
  # asked for UTC, so a different value means the caller has been given the
  # event's own zone and it is already an IANA name.
  defp zone_name("UTC"), do: "Etc/UTC"
  defp zone_name(zone), do: zone

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

  @doc """
  The API module a series master can be fetched from, or `nil` for a source
  whose provider has no single-event lookup wired up.

  Resolved from the *integration*, not the cached row's `provider` string: the
  integration is what the API client is handed and what holds the token, and a
  row whose provider disagreed with its integration's would otherwise pick a
  client that cannot authenticate against it.

  Which providers answer is `Capability`'s `:series_lookup` to state, not this
  module's. Matching providers here as well would make two lists of one fact,
  and the drift has a direction: `Eligibility` admits a recurring source it
  believes resolvable, this answers `nil`, and the mirror is discarded with no
  placeholder written and the organiser's time left bookable. Asking the table
  means the gate and the fetch cannot disagree. Public so that the capability
  test can assert exactly that, provider by provider.
  """
  @spec api_module(CalendarIntegrationSchema.t() | any()) :: module() | nil
  def api_module(%CalendarIntegrationSchema{provider: provider}) do
    if Capability.supports?(provider, :series_lookup) do
      client_for(provider)
    end
  end

  def api_module(_integration), do: nil

  # Reached only for a provider the table has already admitted, so this is a
  # *dispatch* among the admitted rather than a second membership test. The
  # difference matters: a provider added to `:series_lookup` and forgotten here
  # falls to the final clause and answers `nil`, which the capability test
  # catches as a disagreement rather than letting it become the silent discard
  # the one-list rule exists to prevent.
  defp client_for(provider) when provider in [:google, "google"],
    do: Config.google_calendar_api_module()

  defp client_for(provider) when provider in [:outlook, "outlook"],
    do: Config.outlook_calendar_api_module()

  defp client_for(_provider), do: nil
end
