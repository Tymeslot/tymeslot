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
```

| Feature | google | outlook | caldav family | ics_url |
| --- | --- | --- | --- | --- |
| `:mirror_target` | yes | yes | yes | **no** |
| `:target_calendar_choice` | yes | yes | **no** | – |
| `:per_event_colour` | yes | **no** | **no** | – |
| `:recurrence` | yes | **no** (stage 2) | **no** (stage 2) | – |

Outlook and CalDAV are marked `no` for `:recurrence` **as a starting position,
not a finding**. Outlook has a structured `recurrence` object rather than an
RRULE and there is already a `RecurrenceConverter` for the inbound direction;
CalDAV takes an RRULE natively. Both are plausible later. Neither is claimed
here, and the table is where that claim gets made when someone verifies it.

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

### C — later, not now

Occurrence-level exceptions (EXDATE patching first, per-instance overrides
second), and verifying whether Outlook's structured recurrence and CalDAV's
native RRULE can flip their `:recurrence` cells to true. Each is a table change
plus its own evidence.
