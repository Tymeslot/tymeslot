defmodule Tymeslot.Integrations.Calendar.SyncLink.Eligibility do
  @moduledoc """
  The one question every mirror write is gated on: may this cached event act as
  the *source* of a placeholder on another calendar?

  Every caller — the sync-path enqueue, the worker, and later the reconcile
  sweep — asks it here. Duplicating the rule at any of those sites is how one of
  them drifts, and the rule this module exists for is the one whose failure mode
  is unbounded.

  ## Why the mirrors table is the authority, not a provider tag

  The loop is the hazard. Two calendars linked in both directions mirror each
  other's events; unless a mirror is recognised as a leaf, the placeholder
  written onto B comes back on B's next inbound sync as an ordinary event, gets
  mirrored onto A, and the pair generate events at each other until a quota
  stops them.

  Recognising a mirror needs an authority, and there are two candidates.

  A **provider-side tag** — a `tymeslotSyncLinkId` in Google's
  `extendedProperties.private`, Outlook's single-value extended property, an
  `X-` property in an iCalendar body — travels with the event and survives the
  local database being lost. But it does not exist yet: Google's
  `add_tymeslot_fingerprint/1` hardcodes `%{"createdBy" => "tymeslot"}` via
  `Map.merge`, so carrying a second property means changing the mapper, the
  normaliser and the `CalendarEvent` struct for three provider families before a
  single mirror can be written. Worse, the tag that *does* exist,
  `created_by_tymeslot`, means "Tymeslot wrote this" and is equally true of
  every booking event — keying loop prevention on it would stop Tymeslot's own
  bookings being mirrored, which is the opposite of what the feature is for.

  The **mirrors table** answers the same question today. It is Tymeslot's own
  bookkeeping rather than a projection of provider state, so no inbound sync
  overwrites it (unlike `provider_metadata`, which is in `replace_fields/0` and
  is wiped wholesale on every sync), and stage 2 built
  `calendar_sync_mirrors_target_uid_index` on `[target_integration_id,
  target_uid]` for exactly this backward lookup. So the rule is: a cached
  event's `{integration_id, uid}` present in the mirror set means it *is* a
  mirror, and a mirror is always a leaf.

  Provider-side tagging is **deferred, not abandoned**. It remains worth adding
  as a recovery mechanism for the case this design does not cover — the local
  mirror row lost while the placeholder survives on the provider — and so that
  external tools can recognise a Tymeslot busy block for what it is. Loop
  prevention will not depend on it when it arrives; it will corroborate.

  ## The scoping rules

  The other three refusals are narrower, and each keeps a wrong placeholder off
  the target rather than preventing a loop:

  - **A recurrence rule the target cannot take.** A recurring series is one
    cache row, not one row per occurrence: `upsert_batch/1` deduplicates by
    `{calendar_integration_id, uid}` keeping the last entry, because Google
    returns many expanded instances sharing a single iCalUID. Mirroring that row
    onto a target that cannot expand a series would write one busy block, at the
    last occurrence's date, where a whole series belongs. A target that *can* —
    `Capability.supports?(provider, :recurrence)` — receives the series as one
    recurring placeholder instead, built from the master's rule.
  - **Transparent.** The event does not consume the owner's time, so a
    placeholder for it would block availability that is genuinely free.
  - **Cancelled or declined.** The time is not taken. This matches
    `CalendarEvent.blocking?/1`, deliberately: an event that does not block
    availability locally has no business blocking it on another calendar.

  Both struct and cache-row shapes are accepted because the callers hold
  different ones — the sync path has `CalendarEvent` structs in hand, while the
  worker re-reads the cache row — and normalising one into the other purely to
  ask a boolean would cost a conversion per event on the hot path.

  ## Two questions, not one

  `mirror_source?/2` answers "should this event have a placeholder?" and gates
  the write. `worth_enqueueing?/2` answers the different question the sync path
  has to ask: "could this event's mirroring state need changing?"

  They differ on exactly the events that have *stopped* being eligible. An event
  cancelled or switched to free may already have a placeholder holding a slot
  the organiser has just freed, and skipping it at enqueue time would leave that
  block on the target until the reconcile sweep noticed. So the sync path
  enqueues those, and the worker — which is the only party that knows whether a
  mapping exists — decides between writing and withdrawing.

  The one refusal that *is* shared is the one where no action can ever be
  needed: an event that is itself a mirror is a leaf, and enqueueing it is how
  the loop starts.

  Recurrence used to be shared too, and stopped being when a target could take
  a series. The reason is not that recurrence became less of a scoping rule but
  that its answer became **per link**, and only one of the two questions is
  asked per link. `Sync.enqueue_mirror_write_backs/2` filters one batch of
  events for *every* link out of the source calendar at once — the per-link loop
  is inside the filter — so the target whose capability decides the answer is
  not in hand there. Both `mirror_source?/3` callers, the write-back worker and
  the reconcile sweep, hold the link.

  So the target capability lives on the write gate alone, which was already the
  single gate the write passes through, and the enqueue gate answers the
  question it can: this event's mirroring state may need changing on *some*
  link. That leaves a recurring source enqueued for a link whose target cannot
  take it, which resolves at the worker exactly as a cancelled event does — the
  placeholder is withdrawn if one exists, and the job is discarded as
  `:not_an_eligible_source` if not. Withdrawal is the important half: a link
  whose target loses `:recurrence`, or a source that becomes recurring after
  having been mirrored, leaves a stale placeholder that must come down, and
  refusing the enqueue would strand it until the reconcile sweep noticed.
  """

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.SyncLink.Capability

  @typedoc """
  The set of `{target_integration_id, target_uid}` pairs identifying every
  placeholder Tymeslot has written, as returned by
  `CalendarSyncMirrorQueries.mirror_uids_for_integrations/1`.
  """
  @type mirror_set :: MapSet.t({integer(), String.t()})

  @typedoc "Either shape a cached event reaches this module in."
  @type source :: CalendarEvent.t() | ProviderCalendarEventSchema.t()

  @doc """
  Whether this event may act as the source of a mirror onto `target_provider`'s
  calendar.

  `mirrors` is the set of `{integration_id, uid}` pairs already known to be
  placeholders. Passing an empty set asserts that none of the events being
  judged is a mirror — correct only when the caller has established that
  separately, and never a safe default on the sync path.

  `target_provider` is the provider of the link's target, in either the atom or
  the string form `calendar_integrations.provider` holds. It decides exactly one
  thing: whether a recurring source may be mirrored, since only a target that
  expands a series can be handed one. Every other refusal is a property of the
  source alone and is unchanged by it.

  It defaults to `nil`, which answers `false` for `:recurrence` like any
  unrecognised provider. That is the conservative reading and the right one: a
  caller that names no target has not established that the destination expands
  series, and a wrong single block is precisely the outcome this rule exists to
  prevent.
  """
  @spec mirror_source?(source(), mirror_set(), String.t() | atom() | nil) :: boolean()
  def mirror_source?(event, mirrors, target_provider \\ nil) do
    not already_a_mirror?(event, mirrors) and
      recurrence_supported?(event, target_provider) and
      not transparent?(event) and
      not off_the_calendar?(event)
  end

  @doc """
  Whether this event is worth a write-back job at all.

  The sync path's gate. Narrower than `mirror_source?/3` on purpose — see the
  moduledoc: an event that has stopped blocking time, or that no link's target
  can take, still needs a job, because the placeholder it may already have must
  be withdrawn, and only the worker can tell whether one exists.

  Recurrence is deliberately *not* asked here even though it is a scoping rule,
  because its answer depends on the link's target and this gate is asked once
  for a batch shared across every link. The narrower question it can answer —
  "could this event's mirroring state need changing?" — is `true` for a
  recurring event, since one link's target may expand a series while another's
  cannot.

  A mirror is refused here as firmly as it is at the write. Enqueueing a job for
  a placeholder is how the loop begins, and the enqueue is the cheapest place to
  stop it — a job that reaches the worker only to be discarded still costs a
  row, a dispatch and a query per mirrored event of every sync.
  """
  @spec worth_enqueueing?(source(), mirror_set()) :: boolean()
  def worth_enqueueing?(event, mirrors), do: not already_a_mirror?(event, mirrors)

  defp already_a_mirror?(%{calendar_integration_id: integration_id, uid: uid}, mirrors)
       when is_integer(integration_id) and is_binary(uid),
       do: MapSet.member?(mirrors, {integration_id, uid})

  # An event missing either half of the key cannot be looked up, so it cannot be
  # shown to be a leaf. Treating it as one anyway would silently stop mirroring;
  # treating it as an ordinary event lets the write proceed and fail loudly.
  defp already_a_mirror?(_event, _mirrors), do: false

  # Only a recurring source consults the target at all, so a non-recurring one
  # is eligible whatever the target is — including for the callers that name no
  # target. Written as "is this refusal inapplicable, or does the target lift
  # it?" rather than as a negated conjunction, because the latter reads as
  # though a capable target could rescue an event refused for another reason,
  # which it cannot: the other clauses in `mirror_source?/3` still apply.
  defp recurrence_supported?(event, target_provider) do
    not recurring?(event) or Capability.supports?(target_provider, :recurrence)
  end

  # The master's id, not the row's rule, for the reason `SyncLink.RecurringSeries`
  # gives at length: `singleEvents=true` returns expanded instances, an instance
  # carries no `recurrence` array at all, and so a Google row's `recurrence_rule`
  # is always nil. A rule-based question therefore answers "not recurring" for
  # every series Google sends, and this refusal — the one that keeps a series
  # away from a target that cannot expand one — never fired.
  #
  # Either mark is enough. A row carrying a rule but no master id is a
  # non-Google ingest, or a Google row from before the expansion was turned on;
  # it is still a series, and still not something a target without `:recurrence`
  # can hold.
  defp recurring?(%{recurring_event_id: id}) when is_binary(id) and id != "", do: true
  defp recurring?(%{recurrence_rule: rule}) when is_binary(rule) and rule != "", do: true
  defp recurring?(_event), do: false

  defp transparent?(%{transparency: transparency}),
    do: transparency in [:transparent, "transparent"]

  defp off_the_calendar?(%{status: status}),
    do: status in [:cancelled, :declined, "cancelled", "declined"]
end
