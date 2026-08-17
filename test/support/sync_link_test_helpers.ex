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
end
