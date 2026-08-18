defmodule Tymeslot.Integrations.Calendar.SyncLink.Capability do
  @moduledoc """
  What a calendar provider can do when it stands at either end of a sync link.

  ## Why this is one module rather than four decisions

  Every asymmetry mirroring depends on was already handled correctly, and each
  in its own place: the ICS-target refusal lived in
  `CalendarSyncLinkSchema.validate_target_writable/1` *and* again as a worker
  discard; the CalDAV calendar-id rule lived in
  `CalendarSyncLinkSchema.clear_calendar_id_for_caldav_target/1` *and* again in
  the hub component; the Google-only colour lived in `Engine.colour_target/1`.
  Four facts, six sites, no single place to ask "what does this link's target
  actually support?".

  The cost is paid when a fifth asymmetry arrives: whoever adds it has to
  rediscover all six sites first, and a reader who wants the answer has to read
  four modules to assemble it. So the facts move here and the sites ask. Nothing
  about *what* is answered changes — this module was introduced as a pure
  refactor of the answers that were already being given.

  ## Strings are the form callers actually hold

  `supports?/2` takes the provider as a string as readily as an atom, because
  `calendar_integrations.provider` is a string column and every caller reaches
  this question holding that string — off the row, or off a form parameter.
  `ProviderConfig.caldav_based?/1` is atom-only with a silent `false` catch-all,
  which is not a hypothetical trap: handed `"nextcloud"` it answers `false`, and
  a CalDAV branch gated on it never fires. That already cost one debugging
  session on this feature. Both forms are answered here, and the test table
  asserts every provider/feature pair in both.

  An unrecognised provider — a typo, a `nil`, a provider retired from the
  registry while its integration rows remain — answers `false` for every
  feature. That is the safe direction in all four cases: a refused link, a
  hidden picker and an unpainted placeholder are all recoverable, while a write
  to an unknown target is an event on a calendar nobody asked for.

  `:demo` answers `false` everywhere. It backs the public demonstration
  calendar rather than one an organiser owns, and a link naming it as a target
  would write busy blocks into something shared.

  `:debug` does **not**, and the two are worth telling apart. It implements the
  full `Provider` behaviour against an in-memory store, which makes it the only
  way to drive this engine end to end without standing up HTTP mocks. The
  registry already keeps it out of production through `@dev_only_providers`, so
  refusing it here would add no safety and would remove the cheapest test path
  the feature has.

  ## The table

  | Feature | google | outlook | caldav family | ics_url |
  | --- | --- | --- | --- | --- |
  | `:mirror_target` | yes | yes | yes | no |
  | `:target_calendar_choice` | yes | yes | no | no |
  | `:per_event_colour` | yes | no | no | no |
  | `:recurrence` | yes | no | yes | no |
  | `:series_lookup` | yes | yes | no | no |

  `:mirror_target` is false for ICS alone: a subscription is a published feed
  and `Ics.Provider.create_event/2` answers `{:error, :read_only}`, so a link
  naming one as its target could never write anything.

  `:target_calendar_choice` is false for the CalDAV family because those
  providers ignore a `:calendar_id` in the payload entirely and always write to
  the primary calendar path. It is false for ICS too, but only as a consequence
  of ICS not being a target at all — nothing consults it there, since the
  `:mirror_target` refusal comes first.

  `:per_event_colour` is true for Google alone. `patch_event_colour/4` lives on
  `Google.GoogleCalendarApi` and is not part of the shared `Provider` behaviour,
  so there is no polymorphic call to make for anyone else.

  ## The recurrence row, and what put the CalDAV family in it

  `:recurrence` says a target can be handed a whole series as **one** event and
  will expand it itself. Google can: `EventMapper.maybe_add_recurrence/2` emits
  `"recurrence" => ["RRULE:..."]`, so one recurring source becomes one recurring
  placeholder and one mirror row rather than one write per occurrence.

  Google's cell was false in the previous stage for one missing piece rather
  than a doubt about Google. Under `singleEvents=true` the cached row is an
  expanded *instance*, and `upsert_batch/1` keeps the last of them — so the
  cached `recurrence_rule` describes whatever the final occurrence carried, not
  the series. Trusting it would place a single busy block at the last
  occurrence's date. `CalendarAPI.get_event/3` now fetches the series master
  through the cached `recurring_event_id`, and `SyncLink.RecurringSeries` reads
  the authoritative rule off it, which is what makes the cell true.

  The CalDAV family can too, and that cell was earned against a live server
  rather than reasoned about. A series is only mirrored correctly when the
  **exception lines** travel with the rule: `EXDATE` is what stops a cancelled
  occurrence from blocking its slot, and an `EXDATE`/`RDATE` pair is what moves
  one. Those lines used to have nowhere to go on this path —
  `recurrence_exception_lines` was read by Google's mapper alone, while the
  CalDAV builder's `build_exdate/1` reads `:recurrence_exceptions`, a
  `[Date.t()]` off the cache that a mirror payload never carries. The rule was
  written and the cancellations were dropped in silence, with the PUT answering
  201.

  `Properties.build_exception_lines/1` is where they go now. It passes a mirror
  payload's pre-built lines through verbatim, gated on a rule being present —
  the same passthrough, for the same reason, that Google's mapper performs, so
  one payload describes a series identically to either family.

  Measured against Radicale on a live round-trip: the stored VEVENT came back
  carrying `RRULE:FREQ=WEEKLY;COUNT=5` and
  `EXDATE;TZID=Europe/Tallinn:20260915T120000`, and the server's own `<C:expand>`
  REPORT returned **four** occurrences rather than five, with the cancelled
  instant absent. The identical write before the fix stored the rule alone and
  expanded to all five. `radicale_recurrence_integration_test.exs` is that
  round-trip; `engine_caldav_series_target_test.exs` and
  `ical_builder_exception_lines_test.exs` pin it without a server.

  **The evidence is one implementation.** Radicale is not Nextcloud, Fastmail or
  iCloud, and none of those was exercised. What makes the cell family-wide
  anyway is that the family shares a single write path — every provider in it
  goes through `ICalBuilder.build_simple_event/2` and the same
  `CaldavCommon.create_event/2` — and what is written is unremarkable RFC 5545
  that a CalDAV server is required to store and expand. A server mishandling it
  would be failing the spec rather than differing from Radicale. That is a
  judgement about risk, not a measurement, and a reader who wants it narrowed to
  `:radicale` has the reason to narrow it written down here.

  ## Outlook stays false, and this is not a gap waiting for a mapper change

  The CalDAV cell was flipped by a passthrough: the exception lines already
  existed on the payload, and a VEVENT has somewhere to put them. Repeating
  that fix for Outlook is not possible, and the reason is in Microsoft's API
  reference rather than in this codebase's reading of it.

  Graph's `recurrence` property takes a `patternedRecurrence`, and that resource
  has **exactly two properties** — `pattern` and `range`. There is no EXDATE
  analogue inside it. There is none on the event body either: the master's
  `cancelledOccurrences` is documented as "Requires `$select` to retrieve. Only
  returned in a Get operation that specifies the ID (**seriesMasterId** property
  value) of a series master event", and it appears nowhere in the create-event
  request reference. It is a read projection of cancellations that already
  happened, not a field a create can set.

  Microsoft models a cancelled or moved occurrence as a **separate
  `exception`-type event** — `type` is one of `singleInstance`, `occurrence`,
  `exception`, `seriesMaster` — reached through `/events/{id}/instances`, which
  requires a `startDateTime`/`endDateTime` window and returns "the occurrences
  and exceptions of the event in the specified time range".

  So there is nowhere for `recurrence_exception_lines` to be passed *to*.
  Honouring a single cancellation on an Outlook target needs a second API call
  per excluded occurrence — list the instances in a window, then DELETE or PATCH
  the matching one. That is not a mapper change; it is N+1 provider writes per
  series, with partial-failure states that leave some occurrences cancelled and
  others not, against the circuit breaker and the per-machine write budget
  `SyncLinkWriteBackWorker` meters — and with no live tenant to verify any of it
  against.

  The failure a flip would produce is the specific one this module exists to
  refuse: the create answers 201, the rule is stored, the cancellations are
  discarded, and every occurrence the organiser called off goes on blocking a
  slot on the target forever, with nothing retrying it because the write
  succeeded. A refusal the organiser can read is strictly better than that.

  **Mirroring a series only when it has no exceptions is not a safer middle
  option, and is in fact the most dangerous one.** It cannot be built correctly,
  because the check has nothing truthful to read. An Outlook *source* always
  resolves with an empty exception list — `read_graph_recurrence/2` sets
  `exceptions: []` unconditionally, because Graph carries no exceptions on the
  master and `calendarView` never returns the exception events beside it. A
  gate reading "this series has no exceptions" would therefore answer *yes* for
  a series with ten cancellations exactly as for one with none, and would mirror
  precisely the series it was added to refuse. The empty list means "not
  visible from here", not "none exist", and only the refusal treats it that way.

  This capability is what the **target** must have; `:series_lookup` below is
  what the **source** side needs, and the two never merge. A CalDAV calendar is
  now a valid *target* for a series while remaining absent from the source row —
  not an inconsistency, but the two ends of one mirror answering different
  questions.

  ## The series-lookup row, and why it is a second question

  `:series_lookup` says a **source** can have the master of one of its series
  fetched. It is the question `SyncLink.RecurringSeries` asks before it can
  describe a series at all: the cached row is an expanded instance carrying no
  rule, so the rule has to be read off the master, and reading it needs a
  single-event GET against the source's own provider.

  It is a separate row from `:recurrence` because the two ends are independent,
  and treating them as one fact is what hid a silent data-loss path. The gate
  asked only whether the *target* could expand a series, so an Outlook or CalDAV
  source pointed at a Google target passed it — the target can expand one —
  reached `RecurringSeries`, and got `{:skip, :provider_has_no_series_lookup}`.
  The worker discarded the job as ineligible, no placeholder was ever written,
  and the organiser's recurring meetings stayed bookable with nothing said.

  Google and Outlook are in this row, and they are there for the same structural
  reason. Every path either provider is synced with expands a series before
  Tymeslot sees it — `singleEvents=true` for Google, `calendarView` for Outlook
  (`list_events/4`, `list_primary_events/3`, and `/me/calendarView/delta`) — so
  the cached row is an occurrence carrying the master's id and no rule, and the
  rule can only be read by fetching the master.

  `Outlook.CalendarAPI.get_event/3` is that fetch. It wraps the existing
  `get_event_raw/2` in the token refresh and the circuit breaker its bare-token
  caller does for itself, so the series path reaches Graph exactly as it reaches
  Google. What differs is the *shape* of the answer: Graph carries a structured
  `pattern`/`range` object rather than a list of iCalendar lines, so
  `RecurringSeries` reads it through `RecurrenceConverter.outlook_to_rrule/1` —
  the same converter the inbound normaliser uses — rather than by matching an
  `RRULE` prefix.

  **The CalDAV family is not a gap waiting to be filled here.** It is absent
  because it has nothing to look up, not because the lookup is unbuilt.
  `ICalNormaliser` expands a CalDAV series *locally*: `expand_event/3` emits one
  raw map per occurrence, `build_uid/1` gives each its own uid — so
  `upsert_batch/1` never collapses the series into a single row the way it does
  for the other two — and `resolve_timing/1` times each row from its own
  occurrence rather than from the master's DTSTART. Every cached CalDAV row is
  therefore already a correctly-timed, uniquely-keyed one-off, mirrored as such
  by the ordinary path. `recurring_event_id` is never set anywhere in the CalDAV
  or iCal code, so no CalDAV row can reach the series path at all.

  **This row is the only list.** `RecurringSeries.api_module/1` resolves its API
  module by asking here rather than by matching providers itself, so the gate's
  answer and the fetch's answer cannot drift apart — which they would, given two
  lists, and the drift's failure mode is precisely the silent discard above.

  ## What the refusal cost, and why it is written down

  This row was false for both other families for one stage, and the reason
  recorded was a real defect rather than caution: the exception lines had no
  mapper on either path. The two halves have since resolved in opposite
  directions, and the difference is worth stating precisely, because they look
  like the same refusal and are not.

  The CalDAV half was a **missing mapper**. The destination existed — a VEVENT
  takes an EXDATE line — and nothing wrote to it. `build_exception_lines/1`
  supplied the passthrough, a live Radicale confirmed the server stored and
  expanded it, and the cell flipped.

  The Outlook half is a **missing destination**, which no mapper can supply.
  Graph has no EXDATE analogue on the recurrence object or the event body, and
  models a cancelled occurrence as a separate `exception`-type event; the write
  it would take is a per-occurrence call, not a field. So this cell is not
  waiting on a round-trip the way the CalDAV cell was. A round-trip would
  confirm what the API reference already states, and would not change the
  answer.

  What would change it is building the per-occurrence write path — and that is
  a deliberate decision with real costs (N+1 writes per series, partial-failure
  states, the circuit breaker and the write budget, and no live tenant to verify
  against), not a cleanup someone should perform on the strength of this cell
  looking unfinished. It is refused, on stated grounds, until someone chooses to
  pay for it.

  The organiser is told either way: `SyncLink.UnmirrorableSeries` writes a
  `series_unsupported` conflict row naming the target as the end at fault, and
  the sync-links tab renders it. That is what makes a refusal an answer rather
  than a silence.

  """

  alias Tymeslot.Integrations.Calendar.ProviderConfig

  @typedoc """
  One thing a provider may or may not be able to do as the target of a sync
  link.

  - `:mirror_target` — can receive a placeholder write at all.
  - `:target_calendar_choice` — honours a `:calendar_id` in the event payload,
    so the organiser's choice of which calendar to write to means something.
  - `:per_event_colour` — has a per-event colour reachable from the mirror
    path.
  - `:recurrence` — can be handed a recurring series as one event and will
    expand it itself. Google and the CalDAV family; Outlook is refused because
    Graph has no EXDATE analogue, so a series would arrive there with its
    cancellations discarded. See the moduledoc.
  - `:series_lookup` — can have the master of one of its series fetched, which
    is what a recurring *source* needs before any rule exists to hand a target.
    Google and Outlook; see the moduledoc.

  The last two are the two ends of one mirror and are deliberately not one
  question: `:recurrence` is asked of the target, `:series_lookup` of the
  source.
  """
  @type feature ::
          :mirror_target
          | :target_calendar_choice
          | :per_event_colour
          | :recurrence
          | :series_lookup

  @caldav_providers ProviderConfig.caldav_based_providers()
  @caldav_provider_strings ProviderConfig.caldav_based_provider_strings()

  @doc """
  Whether `provider` supports `feature`.

  Accepts the provider as an atom or as the string form that comes off
  `calendar_integrations.provider`. Anything unrecognised — an unknown string,
  `nil`, a dev-only provider — answers `false` for every feature, which is the
  safe direction at all four call sites.

      iex> alias Tymeslot.Integrations.Calendar.SyncLink.Capability
      iex> Capability.supports?("nextcloud", :mirror_target)
      true
      iex> Capability.supports?("nextcloud", :target_calendar_choice)
      false
      iex> Capability.supports?(:ics_url, :mirror_target)
      false
      iex> Capability.supports?("google", :per_event_colour)
      true
      iex> Capability.supports?(:google, :recurrence)
      true
      iex> Capability.supports?(:outlook, :recurrence)
      false
      iex> Capability.supports?("nextcloud", :recurrence)
      true
      iex> Capability.supports?(:google, :series_lookup)
      true
      iex> Capability.supports?(:outlook, :series_lookup)
      true
      iex> Capability.supports?("nextcloud", :series_lookup)
      false
  """
  @spec supports?(String.t() | atom() | any(), feature()) :: boolean()
  def supports?(provider, :mirror_target),
    do: known?(provider) and not ProviderConfig.subscription?(provider)

  def supports?(provider, :target_calendar_choice),
    do: supports?(provider, :mirror_target) and not caldav?(provider)

  def supports?(provider, :per_event_colour), do: provider in [:google, "google"]

  # Google and the CalDAV family. Still matched on the provider rather than
  # derived from `:mirror_target`, because "can receive a write at all" and
  # "will expand a series it is handed" are independent questions — Outlook and
  # ICS answer the first and not the second.
  #
  # The CalDAV cell was flipped on a round-trip against a live Radicale, not on
  # a reading of the code. `Properties.build_exception_lines/1` now emits a
  # mirror payload's `recurrence_exception_lines` beside the RRULE, and the
  # server stored both and expanded the series to four occurrences instead of
  # five, with the cancelled one absent from its own expansion. Before that
  # function existed the same write returned 201 with the EXDATE silently
  # dropped, which is the failure the previous refusal was protecting against.
  #
  # Radicale is one implementation; Nextcloud, Fastmail and iCloud are not
  # exercised. The properties involved are ordinary RFC 5545 and the family
  # shares one write path, so the cell is family-wide — but see the moduledoc
  # for what that does and does not rest on.
  #
  # Outlook is absent, and permanently so on the current write path rather than
  # pending a mapper change. Microsoft Graph has no EXDATE analogue anywhere: a
  # `patternedRecurrence` is `pattern` and `range` and nothing else, and the
  # master's `cancelledOccurrences` is read-only (documented as returned only on
  # a GET that `$select`s it, absent from the create reference). A cancelled
  # occurrence is a separate `exception`-type event reached through
  # `/events/{id}/instances`, so honouring one needs a second API call per
  # excluded occurrence rather than a line beside the rule. Flipping this on a
  # mapper change would store the rule, discard the cancellations, answer 201,
  # and block the organiser's called-off slots forever with nothing retrying.
  # See the moduledoc, including why "mirror only exception-free series" is not
  # a safer middle option but the most dangerous one.
  def supports?(provider, :recurrence),
    do: provider in [:google, "google"] or caldav?(provider)

  # Google and Outlook, and asked of the **source** rather than the target. Both
  # are synced through a path that expands a series before it is cached, so the
  # row is an occurrence carrying the master's id and no rule; the CalDAV family
  # is absent because its rows are expanded locally into correctly-timed
  # one-offs and carry no master id to look anything up with. This is the single
  # statement of which providers a series master can be fetched from:
  # `RecurringSeries.api_module/1` reads it rather than repeating the match, so
  # the gate that admits a recurring source and the fetch that resolves it are
  # one fact. Two lists here drift into a source admitted by the gate and
  # refused by the fetch, which is a job discarded and a placeholder never
  # written — the failure this row was added to close.
  def supports?(provider, :series_lookup),
    do: provider in [:google, "google", :outlook, "outlook"]

  # `parse_known/1` rather than `parse/1`, so the answer does not turn on a
  # runtime toggle. A link is configured once and written to for years; a
  # provider switched off in config must not silently make every existing link
  # to it unwritable, which is the outcome a toggle-aware check would produce.
  #
  # `:demo` is excluded. It is a fixture for the public demonstration calendar,
  # not a calendar anyone owns, and a link naming it as a target would write
  # busy blocks into something shared.
  #
  # `:debug` is NOT excluded, and the distinction matters. It implements the
  # full `Provider` behaviour — create, update and delete against an in-memory
  # store — and is the only way to exercise this engine end to end without
  # standing up HTTP mocks for a real provider. It is already kept out of
  # production by the registry itself (`@dev_only_providers`), so excluding it
  # here would buy no safety and would cost the cheapest test path there is.
  defp known?(provider) do
    case ProviderConfig.parse_known(provider) do
      {:ok, parsed} -> parsed != :demo
      {:error, :unknown} -> false
    end
  end

  defp caldav?(provider) when is_atom(provider), do: provider in @caldav_providers
  defp caldav?(provider) when is_binary(provider), do: provider in @caldav_provider_strings
  defp caldav?(_provider), do: false
end
