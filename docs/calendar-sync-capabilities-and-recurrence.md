# Provider capability sets, and recurring-series mirroring

A follow-on to `calendar-sync-plan.md`. That plan deferred recurring events and
treated provider differences as a handful of special cases. This one makes the
differences explicit, and uses that to lift the recurrence restriction for
Google without pretending every provider can follow.

## Why this is one piece of work and not two

Recurrence support is not uniform and never will be. Google can be handed an
RRULE and will expand the series itself; an ICS subscription cannot be written
to at all; CalDAV can carry an RRULE but cannot be told which calendar to write
to. Adding recurrence without first saying, in one place, what each provider
can do would mean a second scattering of `if provider == "google"` through the
payload builder, the worker, the changeset and the UI — the pattern the
codebase currently keeps out of those layers.

So the capability set comes first, and recurrence is its first real consumer.

## Part 1 — the capability set

### What exists today, and where it leaks

Provider asymmetries are already load-bearing and already handled, but each in
its own place:

| Asymmetry | Where it is decided today |
| --- | --- |
| ICS cannot receive writes | `CalendarSyncLinkSchema.validate_target_writable/1`, and again as a worker discard |
| CalDAV ignores `:calendar_id` | `CalendarSyncLinkSchema.clear_calendar_id_for_caldav_target/1`, and again in the hub component |
| Only Google has per-event colour | `Engine.colour_target/1` |
| Recurring sources are skipped | `SyncLink.Eligibility.mirror_source?/2` |

Each is correct. The problem is that adding a fifth asymmetry means finding all
the places again, and that a reader cannot answer "what does this link's target
actually support?" without reading four modules.

### The module

`Tymeslot.Integrations.Calendar.SyncLink.Capability`, answering one question:

```elixir
@spec supports?(String.t() | atom(), feature()) :: boolean()

@type feature ::
        :mirror_target
        | :target_calendar_choice
        | :per_event_colour
        | :recurrence
        | :series_lookup
```

| Feature | google | outlook | caldav family | ics_url |
| --- | --- | --- | --- | --- |
| `:mirror_target` | yes | yes | yes | **no** |
| `:target_calendar_choice` | yes | yes | **no** | – |
| `:per_event_colour` | yes | **no** | **no** | – |
| `:recurrence` | yes | **no** (**refused; Graph has no EXDATE**) | yes (**verified live**) | – |
| `:series_lookup` | yes | yes | **no** (not applicable) | – |

The last two rows are the two ends of one mirror and are deliberately not one
question. `:recurrence` is asked of the **target** — can it be handed a whole
series as one event and expand it itself? `:series_lookup` is asked of the
**source** — can the master of one of its series be fetched, so that there is a
rule to hand anyone at all?

They no longer name the same providers, and the asymmetry is the point.

**`:series_lookup` — Google and Outlook.** Both are synced through a path that
expands a series before Tymeslot caches it (`singleEvents=true` for Google,
`calendarView` for Outlook, including `/me/calendarView/delta`), so the cached
row is an occurrence carrying the master's id and no rule. The rule can only
come from a single-event GET against the master, and both providers now have
one: `Google.CalendarAPI.get_event/3` and `Outlook.CalendarAPI.get_event/3`,
the latter wrapping the pre-existing `get_event_raw/2` in the token refresh and
circuit breaker its bare-token caller does for itself. The master's shape
differs — Google answers a list of iCalendar lines, Graph a structured
`pattern`/`range` object read back through
`RecurrenceConverter.outlook_to_rrule/1` — so `RecurringSeries` dispatches on
the provider rather than generalising.

**`:series_lookup` — the CalDAV family is `no` because the question does not
apply**, not because the lookup is unbuilt. `ICalNormaliser` expands a CalDAV
series *locally*: `expand_event/3` emits one raw map per occurrence,
`build_uid/1` gives each occurrence its own uid — so `upsert_batch/1` never
collapses a series into one row as it does for the other two — and
`resolve_timing/1` times each row from its own occurrence rather than from the
master's DTSTART. Every cached CalDAV row is therefore already a
correctly-timed, uniquely-keyed one-off that the ordinary mirror path handles.
`recurring_event_id` is never set anywhere in the CalDAV or iCal code, so no
CalDAV row can reach the series path regardless.

Note that a CalDAV row *does* carry a `recurrence_rule`: the master's is copied
onto every occurrence. A rule on a CalDAV row is therefore not a signal that the
row describes a series, and forwarding it to a placeholder would write a whole
series starting at that occurrence — once per occurrence.

**`:recurrence` — Google and the CalDAV family; Outlook still `no`.** Both
non-Google families can be handed a *rule*:
`Outlook.EventMapper.add_recurrence/2` converts one into Graph's `recurrence`
object, and `ICalBuilder.Properties.build_rrule_line/1` emits an `RRULE` line
for CalDAV. The question that decides the cell is whether they can also be
handed the **exceptions** that travel with it — the `EXDATE` that stops a
cancelled occurrence blocking its slot, and the `EXDATE`/`RDATE` pair that moves
one.

For one stage neither could, and the cells were `no` for that reason.
`recurrence_exception_lines` was read by exactly one mapper,
`Google.EventMapper.maybe_add_recurrence/2`. The CalDAV builder's
`build_exdate/1` reads `:recurrence_exceptions` — a `[Date.t()]` off the cache,
a different field of a different type that a mirror payload never carries — so
the RRULE was written and the cancellations were dropped in silence, with the
PUT answering 201.

`ICalBuilder.Properties.build_exception_lines/1` is where those lines go now. It
emits a mirror payload's pre-built lines verbatim, gated on a rule being
present. Verbatim matters: the instant an occurrence was cancelled at lives in
the line's `TZID` parameter, which sits between the property name and the colon,
so anything that strips and re-adds a prefix either no-ops or discards the
timezone — and a cancellation that loses its timezone cancels a different
occurrence. `RDATE` is carried alongside `EXDATE` rather than filtered out,
because emitting only the first frees the slot an occurrence left without
booking the one it moved to.

### The evidence that earned the CalDAV cell

Measured against a live Radicale rather than reasoned about. A mirror payload
built the way `Engine` builds one, PUT through the ordinary
`CaldavCommon.create_event/2` path:

```
BEGIN:VEVENT
UID:probe-consistent-11138
DTSTART:20260901T090000Z
DTEND:20260901T093000Z
EXDATE;TZID=Europe/Tallinn:20260915T120000
RRULE:FREQ=WEEKLY;COUNT=5
SUMMARY:Busy
TRANSP:OPAQUE
END:VEVENT
```

That is the document read back off the server, which also generated a full
`VTIMEZONE` for `Europe/Tallinn` on its own. The server's own `<C:expand>`
REPORT then returned **four** occurrences rather than five, with
`20260915T090000Z` absent — the cancellation actually took effect. The identical
write before the fix stored the rule alone and expanded to all five.

Note `DTSTART` is UTC while the `EXDATE` carries a `TZID`. That is not an
inconsistency: 12:00 Tallinn *is* 09:00Z on those dates, and RFC 5545 matches an
`EXDATE` against the instants `DTSTART` generates. The server was asked directly
about this — an `EXDATE` naming a *different* instant is stored happily and
excludes nothing. Production cannot produce that mismatch, because
`RecurringSeries` reads the rule, the exception lines and DTSTART off the one
master event.

`radicale_recurrence_integration_test.exs` is that round-trip, tagged
`:calendar_integration`. It cannot run in CI — no seeded CalDAV image is
published for the workflow — so `ical_builder_exception_lines_test.exs` and
`engine_caldav_series_target_test.exs` pin the same behaviour hermetically on
every ordinary `mix test`. All three tiers were mutation-checked: removing the
emission, filtering out `RDATE`, and stripping the `TZID` parameters each break
both the live tests and the hermetic ones.

### What the evidence does not cover

Radicale is **one** CalDAV implementation. Nextcloud, Fastmail and iCloud were
not exercised, and the cell is family-wide anyway for a structural reason rather
than a measured one: the whole family shares a single write path
(`ICalBuilder.build_simple_event/2` into `CaldavCommon.create_event/2`), and
what it writes is unremarkable RFC 5545 that a CalDAV server is required to
store and expand. A server mishandling it would be failing the spec rather than
differing from Radicale. That is a judgement about risk, and a reader who wants
the cell narrowed to `:radicale` alone has the reason written down here.

### Why the Outlook cell stays `no`, and why no round-trip would change it

`EventMapper.add_recurrence/2` reads `:recurrence_rule` and nothing else, so a
series mirrored there arrives with its cancellations discarded — every cancelled
occurrence blocking a slot on the target with nothing to say why, and nothing
retrying it, because the write succeeded.

The CalDAV fix cannot be repeated. That one worked because the destination
already existed and nothing wrote to it: a VEVENT takes an `EXDATE` line, so a
passthrough was enough. **Microsoft Graph has no destination to pass to**, and
this is established from Microsoft's API reference rather than inferred from
the converter's shape:

- `recurrence` takes a [`patternedRecurrence`][pr], whose property table has
  **exactly two** rows — `pattern` and `range`. No exclusion field of any kind.
- The [`event`][ev] resource's `cancelledOccurrences` is a read projection, not
  an input: *"Requires `$select` to retrieve. Only returned in a Get operation
  that specifies the ID (**seriesMasterId** property value) of a series master
  event."* It does not appear in the [create event][ce] request reference at
  all.
- A cancelled or moved occurrence is a **separate event**: `type` is one of
  `singleInstance`, `occurrence`, `exception`, `seriesMaster`, and exceptions
  are reached through [`/events/{id}/instances`][inst], which requires a
  `startDateTime`/`endDateTime` window.

So honouring one cancellation on an Outlook target takes a second API call per
excluded occurrence — list the instances in a window, then DELETE or PATCH the
match. That is new write traffic with new failure modes, not a mapper change.

This cell is therefore **not** waiting on a round-trip the way the CalDAV cell
was. A round-trip would confirm what the reference already states. What would
change the answer is building the per-occurrence write path, weighed against:
N+1 provider writes per series change; partial failure leaving some occurrences
cancelled and others not; the circuit breaker and the per-machine write budget
`SyncLinkWriteBackWorker` meters; and no live tenant to verify against, which is
how this repo's documented production defects reached green suites.

**Mirroring only exception-free series is not a safer middle option — it is the
most dangerous one.** The check has nothing truthful to read.
`RecurringSeries.read_graph_recurrence/2` sets `exceptions: []`
*unconditionally* for an Outlook master, because Graph carries no exceptions on
the master and `calendarView` never returns the exception events beside it. A
gate reading "no exceptions" would answer yes for a series with ten
cancellations exactly as for one with none, and would mirror precisely the
series it was added to refuse. The empty list means "not visible from here", not
"none exist".

The organiser is told rather than left guessing: `SyncLink.UnmirrorableSeries`
appends a `series_unsupported` conflict row naming the **target** as the end at
fault, and the sync-links tab renders it in plain language. A refusal that is
recorded and rendered is an answer; a silent skip is the defect.

[pr]: https://learn.microsoft.com/en-us/graph/api/resources/patternedrecurrence?view=graph-rest-1.0
[ev]: https://learn.microsoft.com/en-us/graph/api/resources/event?view=graph-rest-1.0
[ce]: https://learn.microsoft.com/en-us/graph/api/user-post-events?view=graph-rest-1.0
[inst]: https://learn.microsoft.com/en-us/graph/api/event-list-instances?view=graph-rest-1.0

Takes the provider as a **string** as well as an atom. `integration.provider`
is a string on the row, and `ProviderConfig.caldav_based?/1` is atom-only with
a silent `false` fallback — the trap that already cost one debugging session on
this feature. `Capability` must not repeat it: the string form is the one
callers actually have.

### The three places it is consulted

Deliberately the three that already exist for this, so no new mechanism:

1. **The changeset** — refuse a link that cannot work. `:mirror_target` is
   already enforced this way; `Capability` replaces the direct
   `subscription?/1` call rather than adding a second rule.
2. **The UI** — hide what the target cannot do rather than offering a control
   that silently does nothing. The calendar picker already does this for
   CalDAV; the recurrence and colour controls join it.
3. **The worker/engine** — a function-head discard, so a hopeless write costs
   no provider request. `colour_target/1` is the shape to follow.

A capability must be checked at **both** configuration time and write time. A
link is configured once and written to for years, and a target can be
reconnected as a different provider in between. Configuration-time checks are
for the organiser; write-time checks are for correctness.

## Part 2 — recurring series, Google only

### Why the current restriction exists

Not because recurrence is unmodelled — `provider_calendar_events` carries
`recurrence_rule`, `recurrence_exceptions` and `recurring_event_id`, and
`Utils.RecurrenceExpander` already parses FREQ/INTERVAL/UNTIL/COUNT/BYDAY and
honours EXDATEs.

The reason is narrower and lives in two verified lines:

- `GoogleCalendarApi.list_events/4` sends **`"singleEvents" => "true"`**
  (`google_calendar_api.ex:60`, and again at `:307` for the incremental path),
  so Google expands a series before Tymeslot sees it and returns one item per
  occurrence.
- Every one of those items carries the **same `iCalUID`**
  (`event_normaliser.ex:50` maps `uid` from it), and the cache's unique index
  is `(calendar_integration_id, uid)`. `upsert_batch/1` therefore dedupes them,
  **keeping the last** (`provider_calendar_event_queries.ex:145-159`).

So a weekly series does not merely collapse to one row — it collapses to a row
holding the *final* occurrence's `start_at`/`end_at`, because `orderBy` is
`startTime`. Mirroring that row would place a single busy block at the last
occurrence of the series. That is why `Eligibility` skips recurring sources,
and skipping is the right behaviour until the series itself can be described.

### The shape that works: mirror the series, not the occurrences

Google's outbound mapper **already writes recurrence**:
`GoogleEventMapper.maybe_add_recurrence/2` (`event_mapper.ex:197`) emits
`"recurrence" => ["RRULE:..."]` whenever the payload carries a
`recurrence_rule`. Nothing needs to be built there.

So one recurring source becomes **one** recurring placeholder on the target,
and Google expands it. One `calendar_sync_mirrors` row per series. One provider
write per change rather than one per occurrence — which also keeps the quota
risk flat, unlike the instance-level alternative.

### The one genuine gap: a trustworthy RRULE

The cached row's `recurrence_rule` cannot be trusted as a description of the
series. Under `singleEvents=true` the row is an *instance*, and its rule is
whatever the last expanded instance happened to carry.

The series master must be fetched. The handle is already cached:
`recurring_event_id` (Google's `recurringEventId`) is a column and is populated
by the normaliser (`event_normaliser.ex:55`).

**This needs a new API function.** `GoogleCalendarApi` today has
`list_events/4`, `list_primary_events/3`, `create_event/3`, `update_event/4`,
`patch_event_colour/4`, `delete_event/3` and `list_events_incremental/1` —
there is **no single-event GET**. Adding `get_event/3` is the one piece of
genuinely new provider surface this work requires. It must go through
`AccessToken.with_access_token/3` and the existing `CalendarCircuitBreaker`
like every other call.

Fetching the master is one request per recurring series per change, not per
occurrence, and only for series — so it is bounded by how many recurring
sources a link has, not by how often they occur.

### Occurrence-level exceptions

A single occurrence moved or cancelled is **out of scope for the first cut**,
and the failure must be *visible* rather than silent. When the series master
reports `EXDATE`s, or when an instance carries a `recurringEventId` whose times
diverge from the rule, the mirror is written from the series rule alone and a
`calendar_sync_conflicts` row records the divergence — the log built in stage 5
exists for exactly this. The organiser sees "this series has exceptions the
placeholder does not reflect" instead of a quietly wrong busy block.

**This was lifted.** A moved occurrence now moves the block with it: the slot it
left is freed and the slot it went to is blocked, both carried on the same
repeating placeholder rather than a second event, through an `EXDATE`/`RDATE`
pair on the placeholder the engine already rewrites. It is still recorded in the
conflict log, which is what an organiser reads when a calendar looked wrong and
they want to know why.

The limit that remains is detection, not correction: it reads a marker only
Google supplies, so a move on a CalDAV source is neither corrected nor reported.

The original reasoning, kept because it explains what was weighed: lifting this
means either patching the mirror's EXDATE set (cheap, covers cancellations) or
writing per-instance overrides (expensive, covers moves).
Cancellations are the common case and the cheaper half.

### What must not change

`upsert_batch/1`'s dedup, and the cache's `(calendar_integration_id, uid)`
unique index. Both are shared by availability, booking validation, the grid and
every provider. Making instances distinct rows would mean a new unique key on a
table those four paths depend on, for a gain the series-level design already
delivers. The instance-level design was considered and rejected on that basis.

## Stages

Each ends with the full gate list green, as before.

### A — `feat/calendar-sync-capabilities`

The `Capability` module and the migration of the four existing asymmetries onto
it. **No behaviour change**: this is a refactor whose deliverable is that the
existing tests still pass, plus a table test asserting each provider/feature
pair. The recurrence row is added here returning `false` for everyone, so the
next stage changes one cell rather than adding a concept.

**Done when:** every existing provider special case reads from `Capability`;
`supports?/2` accepts atom and string providers; the ICS-target refusal, the
CalDAV picker hiding and the colour discard all still behave identically, with
their existing tests untouched and green.

### B — `feat/calendar-sync-google-recurrence`

`GoogleCalendarApi.get_event/3`; a series-master fetch keyed on
`recurring_event_id`; `Capability.supports?(:google, :recurrence)` flipped to
true; `Eligibility` allowing a recurring source **only** when the target
supports it; the payload carrying the master's RRULE.

**Done when:**

- a weekly Google source produces exactly one recurring placeholder on a Google
  target, carrying the source's RRULE, with one mirror row — asserted on the
  payload handed to the provider, not only on the stored row;
- the same source against an Outlook or CalDAV target is still skipped, and the
  skip is visible rather than silent;
- a series whose master reports EXDATEs writes the placeholder and logs a
  conflict row naming the divergence;
- deleting the source deletes the one placeholder;
- the series-master fetch happens once per series per change, not once per
  occurrence — asserted by counting provider calls;
- a source whose `recurring_event_id` is absent, or whose master fetch fails,
  falls back to skipping rather than mirroring a wrong single block.

### C — Outlook as a recurring source

`Outlook.CalendarAPI.get_event/3` added as a behaviour callback wrapping
`get_event_raw/2` with token refresh and the shared circuit breaker;
`Capability`'s `:series_lookup` cell for Outlook flipped to `yes`;
`RecurringSeries.read_recurrence/3` dispatching on the provider so Graph's
structured recurrence is converted rather than prefix-matched.

Asserted on the payload the provider is handed, matching the Google path's
depth: the converted RRULE reaches the target, the placeholder starts at the
master's first occurrence rather than the cached row's last, the all-day branch
follows the master, a bounded series keeps its `UNTIL`, the fetch costs one
request per series per change, and a master whose pattern the converter cannot
express is skipped rather than mirrored as a bare one-off.

CalDAV was examined in the same pass and needed nothing — see the
`:series_lookup` note above. Its rows arrive pre-expanded and correctly timed.

### D — later, not now

The CalDAV half of this is **done**: `build_exception_lines/1` carries a mirror
payload's `EXDATE`/`RDATE` lines into the VEVENT, verified against a live
Radicale, which is what flipped that `:recurrence` cell.

Two pieces remain, and only one of them is ordinary unfinished work.

**Per-instance overrides** — an occurrence moved to a different time being
mirrored as a modified instance rather than as an `EXDATE`/`RDATE` pair — are
unbuilt for every family.

**Outlook target support is refused rather than pending**, and the distinction
matters for anyone reading this list as a queue. Graph has no `EXDATE`
analogue: `patternedRecurrence` is `pattern` and `range` and nothing else,
`cancelledOccurrences` is read-only, and a cancelled occurrence is a separate
`exception`-type event. There is no mapper change that would earn the cell —
only a per-occurrence write path, whose costs are set out above. Until someone
chooses to pay for it, the link is refused and the organiser is told with a
`series_unsupported` conflict row.

The **source** side has a bounded known wrong that per-occurrence work would
also close: an Outlook source resolves with an empty exception list, because
Graph carries no exceptions on the master and `calendarView` does not return
them beside it, so a cancelled occurrence of an Outlook series goes on blocking
its slot on a Google or CalDAV target. That is one occurrence rather than a
whole series at the wrong date, and it is stated in `RecurringSeries`'
moduledoc rather than left to be discovered from an empty list.

### Reachability

Everything in stage C ships on tests and fixtures alone. The organiser's live
installation has two Google integrations, no Outlook and no CalDAV calendar, so
no part of the Outlook series path — nor the CalDAV finding — can be exercised
against live data. The fixtures are written against the production mappers and
normalisers they mirror, and each names the function it copies, but that is
evidence about the code rather than about a real provider response.

The Outlook `:recurrence` refusal is a partial exception to that limit, and in
the useful direction. It rests on Microsoft's published API reference — the
`patternedRecurrence` property table, the `cancelledOccurrences` description on
`event`, and the `instances` endpoint — rather than on a fixture or on a reading
of this codebase's converter. No tenant is needed to establish that a field does
not exist. What a tenant *would* be needed for is the opposite claim: anyone
proposing to flip that cell is proposing per-occurrence writes that no test here
can verify, which is precisely the shape of the defects this document's fixtures
section warns about.
