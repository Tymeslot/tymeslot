# Cross-calendar busy-block synchronisation

## What this adds

When an event exists on one connected calendar, a corresponding "Busy"
placeholder is created, updated and deleted on the user's other connected
calendars. External tools booking against any of those calendars then see
accurate availability, independently of Tymeslot's own booking-page
availability check.

Today Tymeslot only *reads* external calendars into `provider_calendar_events`
to check availability at booking time. It never writes a mirrored event onto a
calendar the user did not book through Tymeslot for. This is new capability.

## What already exists

The investigation behind this plan found substantially more existing
infrastructure than a first reading of the codebase suggests. Each item below
was verified against the source, and each one removes work this plan would
otherwise have to specify.

### Push-first, poll-as-fallback already works

`Tymeslot.Workers.FallbackSyncSweepWorker` runs every 15 minutes
(`config/runtime.exs:307`) and fans out per-integration sync jobs in batches of
50, staggered by `scheduled_at` to avoid a thundering herd. Google and Outlook
use webhook channels as the primary trigger; the sweep is the fallback.

CalDAV delta support is complete, in three tiers
(`lib/tymeslot/integrations/calendar/caldav/sync.ex:5-22`):

| Tier | Mechanism | Cadence in the sweep |
| ---- | --------- | -------------------- |
| 1 | `DAV:sync-token`, RFC 6578 sync-collection REPORT | every 15 min |
| 2 | `cs:getctag` PROPFIND, skips fetch when unchanged | every 30 min |
| 3 | Full PROPFIND + calendar-query | every hour |

So the trigger model this feature needs is already built. This plan adds a
reconciliation sweep for *mirror state*, which is a different concern from the
inbound sweep, and schedules it separately.

### Loop-prevention tagging already exists for Google and Outlook

Both providers already stamp an origin marker on write and read it back on
normalisation:

| Provider | Property | Write | Read |
| -------- | -------- | ----- | ---- |
| Google | `extendedProperties.private.createdBy = "tymeslot"` | `google/event_mapper.ex:54` | `google/event_normaliser.ex:71` |
| Outlook | `singleValueExtendedProperties`, id `String {00020329-0000-0000-C000-000000000046} Name createdBy` | `outlook/event_mapper.ex:48` | `outlook/event_normaliser.ex:78` |

The marker lands in the cache as `created_by_tymeslot` (boolean). That column
means "Tymeslot wrote this event", which is not the same as "this is a mirror" —
booking events set it too. This plan therefore adds distinct properties rather
than overloading the existing one.

### The write-back pattern already has a reference implementation

`Tymeslot.Workers.ColourWriteBackWorker` is the closest analogue to what this
feature needs, and its shape is the one to copy:

- a thin enqueue module (`colour_write_back.ex`, 47 lines) that always returns
  `:ok` and logs enqueue failures rather than surfacing them, because the next
  sync reconciles;
- an Oban worker with `unique: [keys: [...], states: [...]]` combined with
  `replace: [:args]` at the enqueue site, so rapid successive changes collapse
  onto one pending job carrying the *latest* value rather than the oldest;
- provider-capability guards as function-head matches returning
  `{:discard, reason}` — e.g. `%{provider: "outlook"}` →
  `{:discard, :provider_has_no_event_colour}`;
- a narrow payload that carries only what the operation needs, because a
  full-field payload forces a REPLACE that silently wipes recurrence,
  attendees, alarms and conference data;
- `etag` passed through as a CalDAV `If-Match` precondition, so a host-side edit
  since the last sync makes the PUT return 412 and Oban retries against fresh
  data instead of reverting to a stale snapshot.

`Tymeslot.Meetings.CalendarEventSync` supplies the other half of the pattern:
the `:ok | {:error, term()} | {:discard, term()}` return contract, the
create→update fallback, the update→create-on-404 recovery, and the orphan
compensation described under "Idempotency" below.

## Open question: none blocking

The task brief for this work stated that the README claims Elastic License 2.0
while the `LICENSE` file contains AGPLv3, and asked for that discrepancy to be
resolved before substantial work.

**The discrepancy does not exist.** A search for "elastic" across every
markdown, Elixir, YAML and JSON file in the repository returns no matches. The
README badge (line 13), the README body (lines 40, 227, 245), `LICENSE` and
`COPYRIGHT` all state AGPLv3 consistently. Nothing is blocked.

Two licensing facts do apply to any future upstream contribution, and are
recorded here so they are not rediscovered later:

- `.github/workflows/licensing.yml` enforces two separate gates on pull
  requests: DCO sign-off per commit, and a one-time CLA acceptance recorded
  against a GitHub username.
- `CLA.md` grants Diletta Luna OÜ a perpetual, irrevocable, sublicensable
  licence to relicense contributions under any terms, including proprietary.
  Accepting it is an affirmative act by a person and cannot be delegated.

Commits on this work carry `Signed-off-by` so the history stays upstreamable,
but the CLA decision belongs to whoever opens a pull request.

## Data model

Three new tables. All follow the conventions in
`priv/repo/migrations/20260806121616_create_calendar_appearances.exs`: explicit
index names where the derived name would exceed Postgres' 63-character
identifier limit, and `excellent_migrations:safety-assured-for-this-file`
annotations with a written justification.

### `calendar_sync_links`

One row per configured mirroring relationship.

| Column | Type | Notes |
| ------ | ---- | ----- |
| `id` | bigserial | |
| `user_id` | FK → `users` | denormalised owner, so a link can be listed without joining both integrations |
| `source_integration_id` | FK → `calendar_integrations` | `on_delete: :delete_all` |
| `target_integration_id` | FK → `calendar_integrations` | `on_delete: :delete_all` |
| `target_calendar_id` | string, nullable | provider calendar within the target; `nil` means the target's primary |
| `privacy_tier` | string, not null, default `"busy_only"` | `busy_only` / `generic_label` / `full_passthrough` |
| `generic_label` | string, nullable | the label used when `privacy_tier = "generic_label"` |
| `mirror_colour` | string, nullable | palette key, validated like `CalendarAppearanceSchema.colour` |
| `enabled` | boolean, not null, default `true` | pause without deleting, so mirrors are not torn down |
| `last_reconciled_at` | utc_datetime_usec, nullable | |
| timestamps | utc_datetime_usec | |

Constraints:

- unique index on `[source_integration_id, target_integration_id, target_calendar_id]`,
  named explicitly;
- a check constraint forbidding `source_integration_id = target_integration_id`;
- both integrations must belong to `user_id` — enforced in the changeset, since
  a database-level check would need a trigger.

Direction is modelled by rows, not by a `direction` column. A bidirectional
relationship is two rows. This keeps every row a single unambiguous
source→target statement, and makes "pause one direction" expressible.

### `calendar_sync_mirrors`

One row per mirrored event. This is the mapping the engine consults on every
change.

| Column | Type | Notes |
| ------ | ---- | ----- |
| `id` | bigserial | |
| `sync_link_id` | FK → `calendar_sync_links` | `on_delete: :delete_all` |
| `source_uid` | string, not null | the source event's `uid` |
| `target_integration_id` | FK → `calendar_integrations` | denormalised from the link; see below |
| `target_provider_event_id` | string, nullable | provider-assigned id of the mirror |
| `target_uid` | string, not null | the UID Tymeslot generates for the mirror |
| `source_updated_at` | utc_datetime_usec, nullable | source `provider_updated_at` at last successful write |
| `source_etag` | string, nullable | source `etag` at last successful write |
| `target_etag` | string, nullable | mirror `etag` after the last write |
| `last_synced_at` | utc_datetime_usec | |
| `state` | string, not null, default `"active"` | `active` / `pending_delete` / `failed` |
| timestamps | utc_datetime_usec | |

Constraints and indexes, all named explicitly:

- unique index on `[sync_link_id, source_uid]` — the engine's mapping lookup;
- index on `[sync_link_id, state]` — the reconciliation sweep's scan;
- index on `[target_integration_id, target_uid]` — the grid's hide lookup.

**Why `target_integration_id` is denormalised, and why the third index exists.**
The engine reads this table forwards, from a link and a source UID. The grid
reads it *backwards*: it holds UIDs cached against a target integration and asks
which of them are mirrors it should hide. Without a target-keyed index that
question is a sequential scan on every grid render.

Measured on a probe table at 100,000 mirror rows (50 links × 2,000 events), for
a week view holding 200 cached UIDs:

| Index set | Plan | Rows discarded | Time |
| --------- | ---- | -------------- | ---- |
| link-keyed indexes only | Seq Scan | 100,000 | 5.71 ms |
| plus `[target_integration_id, target_uid]` | Index Only Scan | 0 heap fetches | 1.02 ms |

The grid re-renders on navigation, on live cache updates, and on every
appearance change, so the scan would recur constantly rather than once. The
denormalised column is what lets the index exist at all: the target integration
is otherwise reachable only by joining through the link.

**Why a separate table rather than a column on `provider_calendar_events`:**
`provider_metadata` is the only existing map column and it is listed in
`replace_fields/0`
(`provider_calendar_event_queries.ex:591`), so every inbound sync overwrites it
wholesale with the raw provider payload. A tag stored there would survive until
the next sync and then vanish. The cache is a projection of provider state;
mirror mappings are Tymeslot's own bookkeeping and need a table that sync does
not clobber.

### `calendar_sync_conflicts`

Append-only audit of every non-trivial resolution.

| Column | Type | Notes |
| ------ | ---- | ----- |
| `id` | bigserial | |
| `sync_link_id` | FK → `calendar_sync_links` | `on_delete: :delete_all` |
| `source_uid` | string, not null | |
| `kind` | string, not null | `both_changed` / `mirror_edited` / `delete_race` / `write_failed` |
| `resolution` | string, not null | `source_won` / `deletion_won` / `skipped` |
| `detail` | map, default `%{}` | timestamps and etags compared, and the error when one applies |
| `occurred_at` | utc_datetime_usec, not null | |
| timestamps | utc_datetime_usec | |

Index on `[sync_link_id, occurred_at]`. Pruned by the existing
`DataRetentionWorker` pattern rather than growing without bound.

### Migration safety

Each table is created empty in its own migration, with the foreign keys
declared as part of `CREATE TABLE` rather than added to a populated table, and
indexes created inside the same migration. That is the case the existing
`calendar_appearances` migration documents as safe, and the same
`safety-assured-for-this-file` annotations apply for `index_not_concurrently`
and `column_reference_added`. `mix excellent_migrations.check_safety` is part of
the gate list run at the end of every stage.

## Recognising a mirror

A placeholder that is not recognised as a leaf comes back on the target's next
inbound sync as an ordinary event and is mirrored again, and a pair of linked
calendars then generate events at each other until a quota stops them. So
something has to answer, for any cached event, whether Tymeslot wrote it.

**The mirrors table is the authority.** A cached event's `{integration_id,
uid}` present in the mirror set means it *is* a mirror, and a mirror is always a
leaf. This is Tymeslot's own bookkeeping rather than a projection of provider
state, so no inbound sync overwrites it — unlike `provider_metadata`, which is
in `replace_fields/0` and is wiped wholesale on every sync — and
`calendar_sync_mirrors_target_uid_index` on `[target_integration_id,
target_uid]` exists for exactly this backward lookup.

**The rule lives in one module.** `Calendar.SyncLink.Eligibility` answers
`mirror_source?/3` for a cached event, and the sync-path enqueue, the worker and
the reconcile sweep all go through it. Duplicating it per provider is how one
copy drifts, and this is the rule whose failure mode is unbounded.

**Provider-side tagging is deferred, not abandoned.** A tag written into the
event itself — a `tymeslotSyncLinkId` in Google's `extendedProperties.private`,
Outlook's single-value extended property, an `X-` property in an iCalendar body
— would travel with the placeholder and survive the local database being lost.
Carrying one means changing the mapper, the normaliser and the `CalendarEvent`
struct for three provider families before a single mirror can be written, and
the tag that already exists, `created_by_tymeslot`, cannot serve: it means
"Tymeslot wrote this" and is equally true of every booking event, so keying loop
prevention on it would stop Tymeslot's own bookings being mirrored. The tag
remains worth adding as a recovery mechanism for the case this design does not
cover — the local mirror row lost while the placeholder survives on the provider
— and so external tools can recognise a Tymeslot busy block. When it arrives it
will corroborate loop prevention, not carry it.

ICS needs no scheme either way: `ics/provider.ex:183` returns
`{:error, :read_only}` for `create_event`, so an ICS subscription can be a sync
*source* but never a target.

## Module layout

All under the existing `Tymeslot.Integrations.Calendar` domain. No new
top-level domain: this is calendar integration behaviour and the existing
namespace already holds appearance, preferences, colour write-back and sync.

| Module | Responsibility |
| ------ | -------------- |
| `Calendar.CalendarSyncLinkSchema` | Ecto schema and changeset for `calendar_sync_links`, including same-user and no-self-link validation |
| `Calendar.CalendarSyncLinkQueries` | all reads and writes for links; no raw `Repo.*` elsewhere |
| `Calendar.CalendarSyncMirrorSchema` | schema for `calendar_sync_mirrors` |
| `Calendar.CalendarSyncMirrorQueries` | mapping lookups by `(sync_link_id, source_uid)`, bulk state transitions |
| `Calendar.CalendarSyncConflictSchema` | schema for `calendar_sync_conflicts` |
| `Calendar.CalendarSyncConflictQueries` | append and list for the dashboard |
| `Calendar.SyncLink.Eligibility` | the single source-eligibility rule, and tag extraction per provider |
| `Calendar.SyncLink.MirrorPayload` | builds the outbound event payload for a given privacy tier, including the transparency and visibility rules |
| `Calendar.SyncLink.Engine` | the create/update/delete orchestration, mirroring `CalendarEventSync`'s shape and return contract |
| `Calendar.SyncLink.WriteBack` | thin enqueue wrapper, always `:ok`, mirroring `ColourWriteBack` |
| `Workers.SyncLinkWriteBackWorker` | performs one mirror write; `unique` + `replace: [:args]`; provider-capability discards |
| `Workers.SyncLinkReconcileWorker` | per-link full re-diff |
| `Workers.SyncLinkReconcileSweepWorker` | cron entry point; fans out per-link reconcile jobs in batches |
| `Calendar.SyncLink` | the context: every write takes the acting `user_id` and verifies ownership before touching a row |

## The user interface

### The panel is a hub tab, not a dashboard section

`calendar_settings` is no longer a standalone section, so following it as a
top-level panel would copy a deprecated shape. `dashboard_live.ex:61-65` defines
`@legacy_integration_tabs`, and `handle_params/3` redirects
`:calendar_integration` to `/dashboard/integrations?tab=calendars` before
anything renders. The sync-links panel is therefore a **tab inside the
Integrations Hub**, which needs no route and no sidebar entry.

Two wiring steps fail *silently* if missed, and both must be covered by a test
rather than by inspection:

- a missing `component_for_action/2` clause falls through to the catch-all at
  `component_dispatch.ex:59-61` and renders the dashboard overview;
- a tab value absent from the `parse_tab/2` whitelist
  (`integrations_hub_component.ex:217-223`) falls back to `:calendars`.

The wiring checklist for the tab:

1. `build_tabs/4` (`integrations_hub_component.ex:77-92`) — the tab entry;
2. `parse_tab/2` whitelist (`:217-223`) — or the tab silently shows Calendars;
3. `attention_items/4` (`:112-119`) — surfaces link health in the hub header;
4. a render branch beside the existing ones (`:254-283`);
5. a component carrying `<.section_header>`, required by
   `dev_support/credo_checks/require_dashboard_section_header.ex`, or a path
   entry in that check's `@helper_paths` allowlist;
6. a rate-limit bucket in `security/rate_limiter/dashboard.ex`, which has its
   own contract test, or a conscious decision to reuse an existing one;
7. `send(self(), {:integration_updated, :calendar})` so sibling components
   refresh — `dashboard_live.ex:265-271` catches it.

Writes follow the established chain: `handle_event` → context with an ownership
check → query module → local re-assign. The ownership pattern to mirror is
`Appearance.with_owned_integration/3` (`appearance.ex:92-98`): the query modules
are not user-scoped, so **a panel that calls a query module directly bypasses
authorisation entirely**. A sync link touches two integrations, so the context
must verify the acting user owns *both*.

There is no PubSub for settings changes today — appearance changes refresh only
the socket that made them. Sync-link edits follow the same rule; cross-session
propagation would be new work and is not in scope.

### Mirrors are hidden from the organiser's own calendar

A mirror is an artifact for external tools. Showing it in the organiser's own
grid would double-draw every synced event beside its source, which is noise
rather than information.

The filter belongs in `do_visible_events/3`
(`calendar_grid/helpers/data_loading.ex:95-101`), which already filters by
hidden integrations and hidden calendars; mirror hiding is a fourth filter in
that same function, fed by the `[target_integration_id, target_uid]` lookup
above.

It must **not** filter on `created_by_tymeslot`. Booking-created events set that
flag too, so filtering on it would hide the organiser's own bookings. It must
also not read `provider_metadata`: that map reaches the UI layer, but each
provider shapes it differently — Google keeps a string-keyed raw payload
(`google/event_normaliser.ex:69`), CalDAV keeps atom-keyed iCal properties
(`utils/ical_normaliser.ex:169`) — and every sync overwrites it wholesale. The
mirrors table is the only stable answer.

### Mirrors still count towards availability

Availability is checked across all of an organiser's calendars together, so a
mirror occupying time on a second calendar is a true statement about that
calendar. Mirrors therefore keep blocking.

This is already the behaviour: `CalendarEvent.blocking?/1`
(`calendar_event.ex:118-124`) returns true for any confirmed, opaque event and
does not consult `created_by_tymeslot`. All three consumers filter through it —
`free_busy.ex:90`, `bookings/validation.ex:101`, `availability/calculate.ex:83`
and `:148`.

Because no code changes, the risk is that a later refactor "optimises" mirrors
out of availability without noticing. The plan therefore adds a test that
**pins** the behaviour: a mirror in the cache must still remove a slot from
availability. That test is the deliverable, not a code change.

### Overlaps across calendars are marked

With mirrors hidden, two real events on different calendars at the same time
render side by side and are easy to miss — precisely the situation this feature
exists to prevent. The grid marks them.

The overlap fact is already computed. `OverlapLayout.overlap_layout/1`
(`calendar_grid/helpers/overlap_layout.ex:45`) assigns greedy columns and
returns `{event, col_idx, total_cols}`, which the template already destructures
at `grid_views.ex:152`. `total_cols > 1` means the event overlaps another, and
each event carries `calendar_integration_id`, so "do these overlapping events
come from different integrations?" is a comparison over data already in hand —
no query and no new assign.

**The marker is a border or ring, never a colour change.** Colour is already
fully occupied: `color_for_event/2`
(`calendar_grid/helpers/event_positioning.ex:49`) resolves a four-level
precedence — event override, per-calendar colour, integration colour, rotation —
and colour is how an organiser tells which calendar an event belongs to.
Repainting a conflicting event would destroy the signal that makes the conflict
worth noticing. The marker composes as an extra class in the existing
interpolation at `grid_views.ex:154`.

Every cross-integration overlap is marked. Marking only overlaps *not yet
covered by a mirror* was considered and rejected: it needs the mirrors lookup
per overlapping pair at render time, and it encodes a rule ("this overlap is
fine, a busy block exists") that a border cannot convey.

### Translatable strings

Every user-facing string in the panel is a translation obligation, and the
suite enforces it.

There are **six** locales — `en de fr it uk cs` (`config/config.exs:221-229`).
Strings use `dgettext/3` with a domain from the allowlist in
`dev_support/credo_checks/gettext_domain_boundary.ex:78-88`; a bare `gettext/1`
is a Credo failure, and a new domain must be added to that list.

After adding strings, `mix gettext.extract --merge` regenerates the `.pot` and
merges into all six `.po` files — **7 files per domain**. The translations must
then actually be written: `test/support/gettext_completeness_case.ex` fails
`mix test` on any empty `msgstr` or any `#, fuzzy` entry in a non-default
locale. CI's `gettext.extract --check-up-to-date` only checks that the templates
are not stale; completeness is the test suite's job.

### Account deletion removes mirrors

Mirrors live on a provider, not in Postgres, so deleting a user's rows leaves
busy blocks on their external calendars forever.
`Auth.Behaviours.AccountDeletionHook` exists for exactly this — tearing down
state outside Core's database — and returning `{:error, reason}` from it aborts
the deletion. Mirror teardown runs there, before the account rows go.

## Where the engine hooks in

The inbound pipeline has one near-universal chokepoint and three bypasses. Both
were verified.

`Calendar.Sync.persist_normalised_events/2` (`sync.ex:66`) and
`Sync.post_commit_reconciliation/2` (`sync.ex:134`) cover Google, the Outlook
webhook worker, CalDAV and debug. Three inbound paths bypass `Sync` and reach
`ProviderCalendarEventQueries.upsert_batch/1` directly:

- ICS feed refresh, via `full_refresh_for_integration/2`
  (`sync_ics_calendar_worker.ex:122`);
- Outlook delta sweep (`outlook/delta_sync.ex:128`);
- Outlook bootstrap (`outlook/graph_subscription.ex:66`).

The engine hooks into `Sync.post_commit_reconciliation/2`, and the three bypass
sites each gain an explicit call. Hooking `upsert_batch/1` instead would give
blanket coverage, but it runs inside a `Repo.transaction` on the CalDAV path
(`caldav/sync_reconciler.ex:316` and `:353`), so side-effecting work there would
have to be deferred to post-commit anyway. Enqueueing from the post-commit seam
keeps the transaction clean and matches where the existing broadcast and meeting
reconciliation already run.

Because the write-back is an Oban enqueue and never a provider call in the sync
path, a slow or failing target cannot stall an inbound sync.

## Privacy tiers

Three tiers per link. `full_passthrough` is never the default for a new link.

| Tier | Mirror content |
| ---- | -------------- |
| `busy_only` (default) | title "Busy"; no description, location, attendees or conferencing link |
| `generic_label` | the link's `generic_label` as title; nothing else |
| `full_passthrough` | title, description and location copied; attendees and conferencing still omitted |

Two rules override the tier, both driven by fields already modelled on
`ProviderCalendarEventSchema`:

- a source event with `transparency = "transparent"` generates no mirror at all,
  at any tier — it does not consume the owner's time, so mirroring it would
  block availability falsely. An existing mirror whose source becomes
  transparent is deleted.
- a source event with `visibility = "private"` or `"confidential"` never passes
  its real title through, even on `full_passthrough`. It degrades to the
  `busy_only` rendering.

Attendees are never copied at any tier. Mirroring an attendee list onto a second
calendar would send invitations from the mirror, which is both surprising and
outside what a busy block is for.

## Reconciliation sweep

A new Oban cron entry, separate from `FallbackSyncSweepWorker` because it
reconciles mirror state rather than pulling provider state:

```
{"20,50 * * * *", Tymeslot.Workers.SyncLinkReconcileSweepWorker}
```

Every 30 minutes, offset from the :00/:15/:30/:45 slots the existing crontab
already uses, so the two sweeps do not contend for the same provider quota
window. The sweep itself does no provider I/O: it selects enabled links whose
`last_reconciled_at` is older than the interval and enqueues one
`SyncLinkReconcileWorker` per link, batched and staggered exactly as
`FallbackSyncSweepWorker` does.

Per link, the reconcile worker re-diffs full state: every eligible source event
in the sync window against every mapping row, producing creates for unmapped
sources, deletes for mappings whose source is gone, and updates where the source
changed after `source_updated_at`. This is the safety net for missed webhooks
and silent drift, and it is what makes the push path best-effort rather than
load-bearing.

Both cron files must be updated: `config/runtime.exs` and `config/dev.exs` carry
separate crontabs, and `lib/tymeslot/application.ex:352` validates that critical
workers are present.

## Conflict resolution

| Situation | Resolution |
| --------- | ---------- |
| Mirror edited directly on the target | source overwrites it on the next pass; mirrors are not independently editable |
| Both source and mirror changed since `last_synced_at` | last-write-wins by provider `provider_updated_at`, falling back to `etag` inequality when a timestamp is absent; a `both_changed` row is always written to the conflict log |
| Source deleted while mirror edited | deletion wins |
| Link removed, or either integration disconnected | every mirror that link created is deleted before the link row goes |

No conflict is resolved silently: each writes a `calendar_sync_conflicts` row
that the dashboard surfaces.

Deleting mirrors on link removal cannot be left to `on_delete: :delete_all`,
because the rows to remove live on a *provider*, not in Postgres. The link is
first marked `enabled = false`, its mirrors are transitioned to
`pending_delete`, a worker deletes them from the provider, and only then are the
rows removed. Integration disconnect hooks into
`Calendar.Deletion.delete_with_primary_reassignment/2`, the single entry point
for that flow.

## Idempotency

`CalendarEventSync.persist_or_compensate/3` documents a hazard this feature
shares. If the provider create succeeds but persisting the mapping fails, the
mirror exists with nothing pointing at it, and a retry creates a duplicate —
Google and Outlook assign ids server-side and cannot detect the orphan. The
existing code compensates by deleting the just-created event before surfacing
the error, leaving the retry a clean slate. The mirror engine does the same.

CalDAV is the easier case: its PUT is idempotent on a caller-supplied UID, so
the mirror's `target_uid` is generated deterministically from
`sync_link_id` and `source_uid`, and a repeated write converges rather than
duplicating.

## Risks

**Provider quota under fan-out.** One source event on a link with three targets
is three writes. A bulk change on a busy calendar multiplies accordingly.
Mitigations: the write-back worker's `unique` + `replace: [:args]` collapses
repeated changes to the same event into one pending job; the reconcile sweep
batches and staggers; and every outbound call goes through the existing
`CalendarCircuitBreaker`, which already carries per-provider thresholds
(Google 5 failures / 5 min recovery, CalDAV family 3 / 2 min). No second
breaker is introduced.

**CalDAV cannot target a non-primary calendar.** Verified:
`CaldavCommon.create_event/2`
(`providers/caldav_common.ex:242`) resolves `primary_calendar_path(client)` and
never reads `:calendar_id`, while Google and Outlook both honour it. A CalDAV
target therefore receives mirrors only on its primary calendar. The schema
carries `target_calendar_id` so the model is right, and the UI hides the
calendar picker for CalDAV targets rather than offering a choice that silently
does nothing. Lifting this needs a new `create_event` arity across six CalDAV
providers and is deliberately not in scope.

**Recurring events are out of scope.** A Google recurring series collapses to a
single cache row: `upsert_batch/1` dedupes by `{calendar_integration_id, uid}`
keeping the last entry, because Google returns many expanded instances sharing
one iCalUID (`provider_calendar_event_queries.ex:145-159`). Mirroring from that
row would produce one busy block for a whole series. Sources carrying a
`recurrence_rule` are therefore skipped, and the skip is visible in the
dashboard rather than silent. `Calendar.Utils.RecurrenceExpander` already
expands RRULEs for CalDAV and is the foundation for a later stage, which is not
part of this sequence.

**All-day and multi-day correctness.** All-day events populate
`start_date`/`end_date` and leave `start_at`/`end_at` NULL — the 20260408110831
migration dropped those NOT NULL constraints for exactly that reason, and
`caldav/offline_queue.ex:180-184` reads the date fields for all-day rows. The
mirror payload builder must branch the same way; reading `start_at`
unconditionally yields `nil` and produces an invalid DTSTART. All-day and
multi-day cases get explicit tests.

**Timezone fidelity.** The cache stores `start_at`/`end_at` in UTC plus a
separate `timezone` string. A mirror written from UTC alone displays correctly
but loses the originating zone, which matters when the target renders in a
different zone. The payload carries the source `timezone` through.

**ICS as a target is impossible**, and the UI must not offer it. Enforced in the
link changeset, not only in the picker.

## Testing approach

Write the test first, watch it fail for the reason expected, then implement.
Land the test and its implementation in one commit: a commit adding a failing
test is not independently useful, and one adding an untested implementation
hides what the change is for.

**Assert on rendered output, not only on stored rows.** The existing
`per_calendar_appearance_test.exs` states the rule from experience: *"Storing
the row is not the feature; painting the event is. Asserting only on the stored
colour passes even when no view receives the colour map, which is exactly how
the first version of this shipped broken."* Every UI behaviour in this plan —
mirrors hidden, conflicts marked — is asserted by driving the real selector with
`render_click/1` and inspecting the rendered HTML.

LiveView tests use `TymeslotWeb.LiveCase` with `setup :setup_dashboard_user`,
and enter through `~p"/dashboard/integrations?tab=..."`. A `@moduletag` is
mandatory, enforced by `CredoChecks.TestModuleTagRequired`. Tests that exercise
rate-limited writes need `RateLimiter.clear_all()` in setup, because the bucket
leaks between tests.

Four behaviours carry the most risk and get explicit tests beyond their stage's
own coverage:

| Behaviour | Why it is risky | The test |
| --------- | --------------- | -------- |
| Loop prevention | a mirror that spawns a mirror multiplies without bound | a tagged event is never eligible as a source, asserted through `Eligibility` and again end to end |
| Mirrors hidden from the grid | the wrong filter (`created_by_tymeslot`) would hide real bookings | a mirror is absent from rendered output **and** a booking-created event is still present |
| Mirrors block availability | a later refactor could "optimise" them out | a mirror in the cache removes the slot |
| Orphan compensation | a failed mapping write leaves a duplicate on the provider | a persistence failure after create deletes the provider event |

Provider calls are mocked; no test performs real network I/O. The debug provider
(`providers/debug/provider.ex`) writes to an in-memory store and is the cheapest
way to exercise the engine end to end without HTTP.

## Stages

Each stage ends with the full gate list green. These are every check in
`.github/workflows/verify.yml` and `excluded-suites.yml`:

```
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix sobelow
mix deps.audit
mix excellent_migrations.check_safety
mix test
MIX_ENV=dev mix gettext.extract --check-up-to-date
MIX_ENV=dev mix dialyzer
mix test --only backup_tests
mix test --only oauth_integration
mix test --only calendar_integration test/tymeslot_web/integration/outlook_calendar_integration_test.exs
mix test --only migrations
```

The two `MIX_ENV=dev` gates are easy to omit and both bear directly on this
work: `gettext.extract` catches a stale `.pot` after new panel strings, and
`dialyzer` needs the dev build because `dialyxir` is `only: [:dev]`. The first
`dialyzer` run builds a PLT and takes several minutes; later runs are fast.

`mix test` alone leaves roughly 100 tagged tests unexecuted.

### 1 — `feat/calendar-sync-plan`

This document.

**Done when:** the plan is committed and the gate list passes unchanged from
the baseline.

### 2 — `feat/calendar-sync-data-model-and-ui`

Migrations, schemas and query modules for links, mirrors and conflicts, plus the
Integrations Hub tab to create, view, pause and delete links. No syncing logic
runs.

**Done when:**

- schema validations are covered: same-user ownership of both integrations, no
  self-link, no ICS target, palette colour;
- the three indexes exist, including `[target_integration_id, target_uid]`;
- the hub tab renders through `parse_tab/2` and `build_tabs/4`, with a
  `component_dispatch_test.exs` row proving it does not fall through to the
  overview;
- a forged integration id belonging to another user returns `{:error, :not_found}`
  rather than touching a row;
- every new string is translated in all six locales, with
  `mix gettext.extract --check-up-to-date` and the completeness test green;
- creating a link writes a row and nothing reaches a provider.

### 3 — `feat/calendar-sync-one-way-mirror`

The write-back engine for a single direction: on a source change, create,
update or delete a tagged busy-only mirror on the target, via the existing
provider callbacks. Loop-prevention enforced in `SyncLink.Eligibility`. Single
events only, `busy_only` only, one direction only.

**Done when:**

- a source event produces a tagged mirror on the target; editing the source
  updates it; deleting the source deletes it;
- a tagged event never produces a second mirror;
- the orphan compensation path is tested: a create that succeeds on the provider
  but fails to persist its mapping deletes the just-created event;
- a read-only ICS target is rejected before any provider call;
- **the mirror does not appear in the organiser's calendar grid**, asserted on
  rendered output rather than on the filtered list alone;
- **the mirror still removes a slot from availability**, pinning the behaviour
  against a later refactor.

### 4 — `feat/calendar-sync-two-way-and-reconciliation`

Bidirectional links (as paired rows) and multi-target fan-out, plus the
reconcile worker and its cron sweep.

**Done when:** a change on either side mirrors to the other without looping; the
reconcile worker converges a deliberately desynchronised link; and the sweep
enqueues per-link jobs in batches without provider I/O of its own.

### 5 — `feat/calendar-sync-conflict-handling-and-cleanup`

Conflict log and its dashboard surface, last-write-wins by provider timestamp,
deletion-wins races, orphan cleanup on link removal and integration disconnect,
health surfacing through the existing `HealthCheck` domain and the
`calendar_sync_error` email path.

**Done when:** each conflict kind writes exactly one audit row with the compared
values; removing a link deletes every mirror it created before the row goes;
disconnecting an integration does the same; **deleting the account tears down
every mirror through `AccountDeletionHook` before the rows go**; and repeated
write failures mark the link unhealthy through the existing monitor.

### 6 — `feat/calendar-sync-privacy-tiers-and-color`

The three tiers, the transparency and visibility overrides, mirror colour via
`patch_event_colour` with per-link colour storage, and the cross-integration
overlap marker.

**Done when:**

- each tier produces the documented payload;
- a transparent source produces no mirror and removes an existing one;
- a private source never leaks its title at any tier;
- a colour change repaints the mirror on Google and discards cleanly on
  providers without per-event colour;
- two overlapping events from *different* integrations render with the conflict
  marker, two from the *same* integration do not, and the marker leaves each
  event's resolved colour unchanged.

Recurring-event support is a later, separately-landed capability and is not part
of this sequence.
