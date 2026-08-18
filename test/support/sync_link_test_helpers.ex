defmodule Tymeslot.SyncLinkTestHelpers do
  @moduledoc """
  Setup shared by the cross-calendar mirroring tests.

  Every one of them needs the same three rows before it can say anything: an
  organiser, two calendars they own, and a link pointing one at the other. A
  link across two users is a shape the context refuses, so building the trio by
  hand in each file is both repetitive and easy to get subtly wrong — and
  getting it wrong produces a link that cannot exist in production, which is a
  worse failure than a duplicated block.

  ## Why the recurrence and write-response shapes live here too

  The same argument extends past setup to the values a test hands the engine and
  the values it makes a provider answer with. Three production defects reached a
  live installation behind a green suite, and each was a fixture written by hand
  that described something no provider produces:

  - a cache row carrying a `recurrence_rule` *and* a `recurring_event_id`, which
    Google cannot emit — the rule goes on the master, the master id goes on the
    instance, and `singleEvents=true` means only instances are ever cached;
  - a `create_event` answering `%{provider_event_id: ...}`, a key no OAuth
    provider's `convert_event/1` produces, so the id landed under nothing and
    420 live mirror rows recorded `nil`;
  - a write answering the raw string-keyed provider body, which the engine never
    sees because `OAuthBase.handle_write_api_call/2` converts it first.

  Fixing those file by file has already been tried on this branch and the family
  regrew in the files nobody was reading. The cure is that the correct shape is
  the *convenient* one and the illegal shape has no constructor: a caller asking
  for a Google series instance is handed the master id and no rule, and cannot
  add a rule without writing the field out by hand — which is then visible in
  review as the deliberate act it would have to be.

  Every fixture below names the production function whose output it mirrors, so
  the next reader can check the claim against the source rather than trusting
  this moduledoc.
  """

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema

  @doc """
  An organiser with a source calendar, a target calendar, and an enabled link
  from the first to the second.

  Both integrations are Google, the provider that honours `:calendar_id` on
  write and assigns event ids server-side — the combination the engine's
  interesting paths (targeted writes, orphan compensation) are shaped by.
  """
  @spec linked_pair() :: %{
          user: Tymeslot.Auth.UserSchema.t(),
          source: Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(),
          target: Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(),
          link: Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema.t()
        }
  def linked_pair do
    user = insert(:user)
    source = insert(:calendar_integration, user: user, provider: "google")
    target = insert(:calendar_integration, user: user, provider: "google")

    link =
      insert(:calendar_sync_link,
        user_id: user.id,
        source_integration_id: source.id,
        target_integration_id: target.id
      )

    %{user: user, source: source, target: target, link: link}
  end

  @doc """
  A second link out of the same source, onto a freshly created third calendar.

  The fan-out case: one source event on two links is two placeholders.
  """
  @spec extra_target_link(map()) ::
          {Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(),
           Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema.t()}
  def extra_target_link(%{user: user, source: source}) do
    target = insert(:calendar_integration, user: user, provider: "google")

    link =
      insert(:calendar_sync_link,
        user_id: user.id,
        source_integration_id: source.id,
        target_integration_id: target.id
      )

    {target, link}
  end

  @doc """
  The link pointing the other way, making the pair bidirectional.

  This is the configuration loop prevention exists for: without it, a
  placeholder written onto the target comes back on the target's own inbound
  sync as an ordinary event and is mirrored straight back.
  """
  @spec reverse_link(map()) :: Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema.t()
  def reverse_link(%{user: user, source: source, target: target}) do
    insert(:calendar_sync_link,
      user_id: user.id,
      source_integration_id: target.id,
      target_integration_id: source.id
    )
  end

  @default_master_id "master_abc123"
  @default_outlook_master_id "AAMkAGI2master="
  @default_outlook_series_uid "040000008200E00074C5B7101A82E008_weekly"
  @default_caldav_master_uid "weekly-standup@nextcloud.example"
  @default_caldav_rule "FREQ=WEEKLY;BYDAY=TU"
  @default_series_uid "weekly-series@google.com"
  @default_rule "RRULE:FREQ=WEEKLY;BYDAY=TU"

  @doc """
  The cache row a Google recurring series actually produces: one expanded
  instance, marked by the id of the master it belongs to and carrying no rule.

  Mirrors `Google.EventNormaliser.normalise_events/2`, which maps
  `raw["recurringEventId"]` to `recurring_event_id` (`event_normaliser.ex:70`)
  and `raw["recurrence"]` to `recurrence_rule` (`:84`). Google puts `recurrence`
  on the series master alone and `recurringEventId` on the instances alone, and
  `GoogleCalendarApi.list_events/4` sends `singleEvents=true`, so the master is
  never returned by a sync and `recurrence_rule` is `nil` on every cached Google
  row. `RecurringSeries`' moduledoc states it outright: a rule on a Google row
  "is a value that does not occur".

  `recurrence_rule` is therefore fixed at `nil` here and is not overridable
  through `attrs` — a test wanting the impossible pair has to write the struct
  out itself, which is the point.

  Pass `master_id:` to name the series the instance belongs to; it is the handle
  `RecurringSeries` fetches the master with, so a test asserting on that fetch
  needs it to match.
  """
  @spec google_series_instance(
          Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(),
          keyword() | map()
        ) :: ProviderCalendarEventSchema.t()
  def google_series_instance(source, attrs \\ %{}) do
    attrs = Map.new(attrs)
    {master_id, attrs} = Map.pop(attrs, :master_id, @default_master_id)

    instance = %ProviderCalendarEventSchema{
      uid: @default_series_uid,
      calendar_integration_id: source.id,
      provider: "google",
      provider_calendar_id: "primary",
      provider_event_id: "#{master_id}_20261215T090000Z",
      summary: "Weekly standup",
      transparency: "opaque",
      status: "confirmed",
      all_day: false,
      timezone: "Europe/Tallinn",
      start_at: ~U[2026-12-15 09:00:00Z],
      end_at: ~U[2026-12-15 09:30:00Z],
      recurring_event_id: master_id
    }

    struct!(instance, Map.delete(attrs, :recurrence_rule))
  end

  @doc """
  The recurrence markers a Google series instance carries, as attributes to merge
  into a factory insert.

  The struct fixture above cannot serve the tests that need the row in the
  database — `insert(:provider_calendar_event, ...)` takes a keyword list — so
  this is the same statement in the shape those callers can use: the master id
  and nothing else. There is no rule to pass, for the reason
  `google_series_instance/2` gives, and a caller cannot add one without leaving
  the fixture behind.
  """
  @spec google_series_markers(String.t()) :: keyword()
  def google_series_markers(master_id \\ @default_master_id),
    do: [recurring_event_id: master_id]

  @doc """
  The series master as `GoogleCalendarApi.get_event/3` answers it: the raw,
  string-keyed body with `recurrence` as an array of lines.

  This is the shape `RecurringSeries` reads the rule out of, and the only place
  in the system a Google recurrence rule exists at all. `exception_lines` are
  appended to that array the way Google appends its own EXDATEs, so a test
  covering the correction lines starts from a master that already has some;
  `recurrence:` replaces the array outright, for a test that is specific about
  every line in it.

  The start and end are March, earlier than any cached instance: under
  `singleEvents=true` the row that survives the upsert is the series' *last*
  occurrence, and that gap is the whole reason the master is fetched.
  """
  @spec google_series_master(keyword()) :: map()
  def google_series_master(opts \\ []) do
    master_id = Keyword.get(opts, :master_id, @default_master_id)
    rule = Keyword.get(opts, :rule, @default_rule)

    recurrence =
      Keyword.get_lazy(opts, :recurrence, fn ->
        [rule | Keyword.get(opts, :exception_lines, [])]
      end)

    %{
      "id" => master_id,
      "recurrence" => recurrence,
      "start" => %{"dateTime" => "2026-03-03T09:00:00Z"},
      "end" => %{"dateTime" => "2026-03-03T09:30:00Z"}
    }
  end

  @doc """
  The cache row a recurring **Outlook** series actually produces: one expanded
  occurrence, marked by the id of the master it belongs to and carrying no rule.

  Mirrors `Outlook.EventNormaliser.build_calendar_event/2`, which maps
  `raw["seriesMasterId"]` to `recurring_event_id` (`event_normaliser.ex:57`) and
  `raw["recurrence"]` to `recurrence_rule` through
  `RecurrenceConverter.outlook_to_rrule/1` (`:68`, `:137`).

  The two are mutually exclusive on a cached row for the same structural reason
  they are on Google, reached by a different route. Every list and delta path
  Tymeslot uses is `calendarView` — `list_events/4` (`outlook_calendar_api.ex:71`),
  `list_primary_events/3` (`:83`) and `GraphSubscription`'s
  `/me/calendarView/delta` (`graph_subscription.ex:41`) — and `calendarView`
  returns *occurrences*, never the seriesMaster. Graph puts `recurrence` on the
  master alone and `seriesMasterId` on the occurrences alone, so a synced
  Outlook row carries the master id and a `nil` rule.

  `recurrence_rule` is therefore fixed at `nil` and is not overridable through
  `attrs`, exactly as `google_series_instance/2` fixes it: a test wanting the
  impossible pair has to write the struct out itself.

  Unlike Google, the uid is Graph's `iCalUId`, which every occurrence of a
  series shares — so the cache dedupes to the last occurrence here too, and the
  times below are December's for a series that began in March.
  """
  @spec outlook_series_instance(
          Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(),
          keyword() | map()
        ) :: ProviderCalendarEventSchema.t()
  def outlook_series_instance(source, attrs \\ %{}) do
    attrs = Map.new(attrs)
    {master_id, attrs} = Map.pop(attrs, :master_id, @default_outlook_master_id)

    instance = %ProviderCalendarEventSchema{
      uid: @default_outlook_series_uid,
      calendar_integration_id: source.id,
      provider: "outlook",
      provider_calendar_id: "AAMkAGI2primary=",
      provider_event_id: "#{master_id}_20261215T090000Z",
      summary: "Weekly standup",
      transparency: "opaque",
      status: "confirmed",
      all_day: false,
      timezone: "Europe/Tallinn",
      start_at: ~U[2026-12-15 09:00:00Z],
      end_at: ~U[2026-12-15 09:30:00Z],
      recurring_event_id: master_id
    }

    struct!(instance, Map.delete(attrs, :recurrence_rule))
  end

  @doc """
  The Outlook series master as `OutlookCalendarAPI.get_event/3` answers it: the
  raw, string-keyed Graph body with `recurrence` as a **structured object**
  rather than an RRULE string.

  This is the shape difference that makes Outlook's series path its own rather
  than a copy of Google's. Graph does not accept or emit RRULE — it carries a
  `pattern`/`range` pair — so the rule has to come back through
  `RecurrenceConverter.outlook_to_rrule/1`, the read direction that already
  exists for the normaliser (`recurrence_converter.ex:63`).

  Mirrors what `get_event_raw/2` returns for `/me/events/{id}`
  (`outlook_calendar_api.ex:312-320`) under `@event_sync_select_fields`
  (`:29`), which requests `recurrence`, `seriesMasterId`, `start`, `end` and
  `type`. A master answers `type: "seriesMaster"` and a `null` `seriesMasterId`.

  The start and end are March — the series' first occurrence — deliberately
  earlier than any cached instance, because `calendarView` dedupes the cache to
  the *last* occurrence and that gap is the whole reason the master is fetched.
  """
  @spec outlook_series_master(keyword()) :: map()
  def outlook_series_master(opts \\ []) do
    master_id = Keyword.get(opts, :master_id, @default_outlook_master_id)

    recurrence =
      Keyword.get(opts, :recurrence, %{
        "pattern" => %{"type" => "weekly", "interval" => 1, "daysOfWeek" => ["tuesday"]},
        "range" => %{"type" => "noEnd", "startDate" => "2026-03-03"}
      })

    %{
      "id" => master_id,
      "type" => "seriesMaster",
      "seriesMasterId" => nil,
      "iCalUId" => @default_outlook_series_uid,
      "subject" => "Weekly standup",
      "recurrence" => recurrence,
      "isAllDay" => false,
      "start" => %{"dateTime" => "2026-03-03T09:00:00.0000000", "timeZone" => "UTC"},
      "end" => %{"dateTime" => "2026-03-03T09:30:00.0000000", "timeZone" => "UTC"}
    }
  end

  @doc """
  The cache row a recurring **CalDAV** source produces, which is not a series
  handle at all but one fully-formed occurrence.

  Mirrors `ICalNormaliser.build_calendar_event/3`, and it is the fixture that
  states why CalDAV needs no master fetch:

  - `expand_event/3` (`ical_normaliser.ex:81`) expands the RRULE locally and
    emits one raw map per occurrence, each stamped `_occ_start`/`_occ_end`;
  - `build_uid/1` (`:301`) gives each occurrence a **distinct** uid,
    `"<master UID>_<occurrence stamp>"`, so `upsert_batch/1` does not collapse
    the series into one row the way it does for Google and Outlook;
  - `resolve_timing/1` (`:206`) times the row from `_occ_start`, so the row
    holds **its own** occurrence's start rather than the master's DTSTART;
  - `recurrence_rule` (`:163`) is copied from the master onto *every*
    occurrence, so a rule on a CalDAV row does not mean the row is a master;
  - `recurring_event_id` is never set anywhere in the CalDAV or iCal paths, so
    it is always `nil`.

  Together those mean each cached CalDAV row is already a correctly-timed,
  uniquely-keyed one-off. Passing the master's rule through would describe a
  whole series starting at this occurrence — once per occurrence.
  """
  @spec caldav_series_occurrence(
          Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(),
          keyword() | map()
        ) :: ProviderCalendarEventSchema.t()
  def caldav_series_occurrence(source, attrs \\ %{}) do
    attrs = Map.new(attrs)
    {occurrence_start, attrs} = Map.pop(attrs, :occurrence_start, ~U[2026-03-10 09:00:00Z])

    stamp = Calendar.strftime(occurrence_start, "%Y%m%dT%H%M%SZ")

    occurrence = %ProviderCalendarEventSchema{
      uid: "#{@default_caldav_master_uid}_#{stamp}",
      calendar_integration_id: source.id,
      provider: "nextcloud",
      provider_calendar_id: "/calendars/organiser/personal/",
      provider_event_id: "#{@default_caldav_master_uid}.ics",
      summary: "Weekly standup",
      transparency: "opaque",
      status: "confirmed",
      all_day: false,
      timezone: "Europe/Tallinn",
      start_at: occurrence_start,
      end_at: DateTime.add(occurrence_start, 1800, :second),
      recurrence_rule: @default_caldav_rule,
      recurring_event_id: nil
    }

    struct!(occurrence, Map.delete(attrs, :recurring_event_id))
  end

  @doc """
  What an OAuth `create_event/2` or `update_event/3` hands back.

  Mirrors `Google.Provider.convert_event/1` (`google/provider.ex:103`) as it is
  reached: `OAuthBase.handle_write_api_call/2` runs the raw body through it and
  merges the etag onto the result (`oauth_base.ex:141-159`). So the map is
  **atom-keyed**, the provider's own event id is under `:uid`, and the etag —
  when the provider reported one — is under `:etag`, already stripped of its
  quotes by `WriteEtag.extract/1`.

  There is no `provider_event_id` key, and that is the whole reason this exists.
  `ProviderEventId.extract/1` matches `%{provider_event_id: id}` first, so a
  mock inventing that key takes a clause only a hand-written internal caller
  ever reaches, while real OAuth traffic falls through to the `uid` clause. Every
  such mock passed while the live path stored `nil`.

  Pass `etag:` for a provider that reported one — give it unquoted, as the
  engine receives it.
  """
  @spec oauth_write_response(String.t(), keyword()) :: {:ok, map()}
  def oauth_write_response(provider_event_id \\ "target-pid-1", opts \\ []) do
    event = %{
      uid: provider_event_id,
      summary: Keyword.get(opts, :summary, "Busy"),
      description: nil,
      location: nil,
      all_day: false,
      start_time: Keyword.get(opts, :start_time, ~U[2026-07-03 09:00:00Z]),
      end_time: Keyword.get(opts, :end_time, ~U[2026-07-03 10:00:00Z]),
      status: "confirmed",
      transparency: "opaque",
      meet_url: nil
    }

    case Keyword.get(opts, :etag) do
      nil -> {:ok, event}
      etag -> {:ok, Map.put(event, :etag, etag)}
    end
  end

  @doc """
  What `OutlookCalendarAPI.create_event/2` and `update_event/3` hand back — the
  layer *below* the provider wrapper, which is where Outlook differs from
  Google.

  Mirrors `convert_to_common_format/1` (`outlook_calendar_api.ex:496-511`), the
  fixed atom-keyed map every Outlook write is narrowed to before it reaches
  `OAuthBase.handle_write_api_call/2`. Google's API module answers the raw body
  instead (`google_calendar_api.ex:113`), so a Google mock returning
  string-keyed JSON is faithful while an Outlook one is not.

  The `:etag` key is the one this fixture exists to pin, and it is the key the
  narrowing had to be taught to carry. Graph annotates every event entity with
  `@odata.etag` — an OData annotation returned regardless of `$select` — but
  `convert_to_common_format/1` named ten keys, none of them an etag, so the
  value was dropped a layer *below* the wrapper meant to keep it and every
  Outlook mirror row stored `nil`.

  It is given here as Graph's **weak** tag, `W/"..."`, because that is the form
  Graph actually sends. `clean_etag/1` trims the trailing quote and leaves the
  inner one, so the cleaned value is the untidy `W/"CQAAABYAAADXbZ3` — which is
  the right answer here, since the cache side is cleaned by the very same
  function and the two only have to agree with each other.
  """
  @spec outlook_write_response(String.t(), keyword()) :: map()
  def outlook_write_response(provider_event_id \\ "AAMkAGI2TG93AAA=", opts \\ []) do
    %{
      id: provider_event_id,
      summary: Keyword.get(opts, :summary, "Busy"),
      description: nil,
      location: nil,
      start: %{"dateTime" => "2026-07-03T09:00:00.0000000", "timeZone" => "UTC"},
      end: %{"dateTime" => "2026-07-03T10:00:00.0000000", "timeZone" => "UTC"},
      is_all_day: false,
      status: "confirmed",
      show_as: "busy",
      response_status: "organizer",
      etag: Keyword.get(opts, :etag, "W/\"CQAAABYAAADXbZ3\"")
    }
  end

  @doc """
  The raw Microsoft Graph body an event write answers with, before
  `convert_to_common_format/1` narrows it.

  This is what the HTTP layer hands `OutlookCalendarAPI.create_event/2`, and the
  only place `@odata.etag` exists — string-keyed, weak-tagged, alongside the
  camelCase property names Graph uses. A test that wants to exercise the
  narrowing itself feeds this to `convert_to_common_format/1`; one that mocks
  the API module wants `outlook_write_response/2` instead, which is what the
  narrowing produces.
  """
  @spec outlook_graph_write_body(String.t(), keyword()) :: map()
  def outlook_graph_write_body(provider_event_id \\ "AAMkAGI2TG93AAA=", opts \\ []) do
    %{
      "@odata.etag" => Keyword.get(opts, :etag, "W/\"CQAAABYAAADXbZ3\""),
      "id" => provider_event_id,
      "iCalUId" => "040000008200E00074C5B7101A82E00800000000",
      "subject" => Keyword.get(opts, :summary, "Busy"),
      "body" => %{"contentType" => "html", "content" => ""},
      "location" => %{"displayName" => ""},
      "start" => %{"dateTime" => "2026-07-03T09:00:00.0000000", "timeZone" => "UTC"},
      "end" => %{"dateTime" => "2026-07-03T10:00:00.0000000", "timeZone" => "UTC"},
      "isAllDay" => false,
      "isCancelled" => false,
      "showAs" => "busy",
      "responseStatus" => %{"response" => "organizer"}
    }
  end

  @doc """
  What the CalDAV family answers a write with, which is not a converted event at
  all.

  `CaldavCommon.update_event/4` is spec'd `:ok | {:error, term()}` and
  `Events.update_calendar_event/5` answers a bare `:ok` on a 200/201/204
  (`caldav/events.ex:225-226`) — the PUT's response ETag is not surfaced by the
  HTTP layer, so there is nothing to convert and nothing to read an etag from.
  `WriteEtag` records `nil` for such a provider by design, which switches the
  three etag-based conflict kinds off rather than inventing a baseline.

  `ProviderEventId.for_update/2` is what turns this into an id: a bare `:ok`
  means the CalDAV server kept the UID it was handed, so the UID the write was
  addressed to *is* the identifier.
  """
  @spec caldav_update_response() :: :ok
  def caldav_update_response, do: :ok

  @doc """
  The placeholder as a Google target's own inbound sync caches it, inserted on
  the given target integration.

  Mirrors `Google.EventNormaliser.build_calendar_event/2`, and specifically the
  two fields the conflict log reads it by:

  - `uid` is `raw["iCalUID"] || raw["id"]` (`event_normaliser.ex:65`). Google
    does not keep the id a create was addressed under: it mints its own iCalUID
    as `{id}@google.com`, so the cached uid is the **suffixed** form of the
    mirror row's `target_provider_event_id`, and there is no row under the
    `target_uid` the write asked for. Measured on a live installation: 105 of
    105 mirrors found this way, 0 of 105 found by `target_uid`.
  - `etag` is `raw["etag"]` stored untouched (`event_normaliser.ex:82`), which
    for Google is an HTTP entity tag with its quotes still on. The mirror row's
    `target_etag` has been through `WriteEtag.extract/1` and has none, so a
    caller wanting the live shape passes the quoted form — that asymmetry is
    real and a test hiding it proves nothing.

  Takes the provider's bare event id and appends the domain itself, so a caller
  cannot accidentally file the row under an identity Google never uses.
  """
  @spec google_cached_placeholder(
          Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(),
          String.t(),
          keyword()
        ) :: ProviderCalendarEventSchema.t()
  def google_cached_placeholder(target, provider_event_id, attrs \\ []) do
    insert(
      :provider_calendar_event,
      Keyword.merge(
        [
          calendar_integration: target,
          uid: provider_event_id <> "@google.com",
          summary: "Busy",
          provider: "google",
          provider_calendar_id: "primary",
          provider_event_id: provider_event_id
        ],
        attrs
      )
    )
  end

  @doc """
  What a CalDAV `create_event/2` answers: `{:ok, uid}` with a bare **string**,
  not a map.

  `CaldavCommon.create_event/2` delegates to `Events.create_calendar_event/4`,
  which is spec'd `{:ok, String.t()}` and answers the UID it PUT the event under
  (`caldav/events.ex:103-108`, `:131`). Nothing here goes through
  `convert_event/1`, so a test mocking a CalDAV create with a map describes a
  provider that does not exist — and `ProviderEventId.extract/1` reads a bare
  string with none of its clauses, answering `nil`.
  """
  @spec caldav_create_response(String.t()) :: {:ok, String.t()}
  def caldav_create_response(uid \\ "target-uid-1"), do: {:ok, uid}

  @doc """
  The VEVENT a live Radicale stores when Tymeslot mirrors a recurring series
  onto it, captured from an actual round-trip rather than composed here.

  Taken from `radicale_recurrence_integration_test.exs` running against Radicale
  on port 8800: the document below is what a `GET` of the created `.ics`
  returned, with the UID and DTSTAMP made stable. Everything else is verbatim,
  including the property *order* — Radicale re-serialises what it is given
  alphabetically rather than preserving the order Tymeslot wrote, which is worth
  having in a fixture because a parser test written against Tymeslot's own
  output order would not be testing what the server sends back.

  Mirrors what `ICalBuilder.build_simple_event/2` produces and
  `CaldavCommon.create_event/2` PUTs — the two halves whose disagreement was the
  bug: the builder emitted the RRULE and dropped the EXDATE beside it, so this
  fixture's exception lines are precisely the part that used to be missing.

  Note DTSTART is UTC while the EXDATE carries `TZID=Europe/Tallinn`. That is
  not an inconsistency: 12:00 Tallinn *is* 09:00Z on these dates, and RFC 5545
  matches an EXDATE against the instants DTSTART generates. The live server was
  asked directly and drops the occurrence for this exact pairing; an EXDATE
  naming a different instant is stored and excludes nothing, which is the trap
  this fixture is shaped to keep out of tests.
  """
  @spec radicale_stored_series_ical(keyword()) :: String.t()
  def radicale_stored_series_ical(opts \\ []) do
    uid = Keyword.get(opts, :uid, "tymeslot-series-1")

    joined_lines =
      opts
      |> Keyword.get(:exception_lines, ["EXDATE;TZID=Europe/Tallinn:20260915T120000"])
      |> Enum.join("\r\n")

    exception_lines = if joined_lines == "", do: "", else: joined_lines <> "\r\n"

    "BEGIN:VCALENDAR\r\n" <>
      "VERSION:2.0\r\n" <>
      "PRODID:-//Tymeslot//CalDAV Client//EN\r\n" <>
      "BEGIN:VEVENT\r\n" <>
      "UID:#{uid}\r\n" <>
      "DTSTART:20260901T090000Z\r\n" <>
      "DTEND:20260901T093000Z\r\n" <>
      "DESCRIPTION:\r\n" <>
      "DTSTAMP:20260818T133600Z\r\n" <>
      exception_lines <>
      "LOCATION:\r\n" <>
      "RRULE:FREQ=WEEKLY;COUNT=5\r\n" <>
      "STATUS:CONFIRMED\r\n" <>
      "SUMMARY:Busy\r\n" <>
      "TRANSP:OPAQUE\r\n" <>
      "END:VEVENT\r\n" <>
      "END:VCALENDAR\r\n"
  end

  @doc """
  The exception lines a mirror payload carries for a series with one cancelled
  occurrence, in the timezone-consistent form the live server honours.

  Mirrors what `SyncLink.RecurringSeries` forwards off a Google master and what
  `SyncLink.MoveCorrection.lines_for/2` builds for a moved one. Pass
  `moved: true` for the `EXDATE`/`RDATE` pair a move produces — both halves,
  because an EXDATE alone frees the slot the occurrence left without booking
  the one it moved to, which widens the double-booking window instead of
  closing it.
  """
  @spec series_exception_lines(keyword()) :: [String.t()]
  def series_exception_lines(opts \\ []) do
    if Keyword.get(opts, :moved, false) do
      [
        "EXDATE;TZID=Europe/Tallinn:20260915T120000",
        "RDATE;TZID=Europe/Tallinn:20260916T120000"
      ]
    else
      ["EXDATE;TZID=Europe/Tallinn:20260915T120000"]
    end
  end
end
