defmodule Tymeslot.Workers.SyncLinkWriteBackWorker do
  @moduledoc """
  Performs one mirror write: the placeholder for a single source event, on a
  single link's target.

  One job per `{link, source event}` rather than one per sync batch. A batch job
  would retry the whole batch when one event's write failed, re-sending every
  other placeholder in it, and would collapse a hundred independent failures
  into one opaque error. Per-event jobs also give `unique` something to key on,
  which is what makes rapid edits collapse instead of racing.

  ## The when, not the what

  Everything this worker decides is about dispatch: which jobs may run, which
  are hopeless, and what an outcome means to Oban.
  `Tymeslot.Integrations.Calendar.SyncLink.Engine` owns the write itself and its
  bookkeeping, and its `:ok | {:error, term()} | {:discard, term()}` contract is
  passed straight through.

  ## Discards, and why each is not a retry

  A discard is the right answer only when no number of attempts could succeed.
  Each of these qualifies:

  - `:link_not_found` — the organiser deleted the link after the job was
    enqueued. There is no target to write to.
  - `:link_disabled` — the link is paused, and the job is not a withdrawal.
    Pausing deliberately leaves existing placeholders alone, so there is
    nothing to do and nothing to undo. A `delete` is the exception and runs:
    `Teardown` disables a link *before* withdrawing its placeholders, so a
    provider that refused one leaves a disabled link still holding
    `pending_delete` rows, and `SyncLinkReconcileWorker.finish_withdrawals/1`
    re-enqueues exactly those. Discarding them strands the placeholder for
    good — nothing else revisits a `pending_delete` mapping.
  - `:target_is_read_only` — a subscription feed. `create_event` returns
    `{:error, :read_only}` for these *always*. The changeset already refuses
    such a target at configuration time; this catches the link configured
    before its target was reconnected as a subscription. It is matched on the
    function head, ahead of every other consideration, so a hopeless write
    never reaches the provider at all.
  - `:source_not_cached` — the source event is gone from the cache and there is
    no mapping to withdraw either. Nothing to mirror and nothing to clean up.
  - `:not_an_eligible_source` — the event fails `Eligibility.mirror_source?/4`:
    it is itself a mirror, transparent, cancelled, or a recurring series on a
    link whose target cannot expand one. The one nuance is that an event which
    *became* ineligible after having been mirrored is not a discard — its
    placeholder is withdrawn first, because a source that has turned
    transparent or been cancelled must stop blocking time on the target.

  ## Why a recurring source on an unsupported target takes that same route

  Since `Eligibility.worth_enqueueing?/2` stopped refusing recurrence, a
  recurring event on a calendar with three links is enqueued for all three, and
  the ones whose targets cannot expand a series arrive here to be turned away.
  They are routed through `unmirror_or_discard/4` rather than discarded
  outright, and the difference is not academic.

  A discard is right only when nothing needs undoing, and here something can:
  the same source may already carry a placeholder on that very target, written
  while it was still a single event and now describing an occurrence that no
  longer stands alone. Discarding would leave that block sitting on the
  organiser's calendar until the reconcile sweep happened to look. Asking the
  mapping table first costs one indexed lookup, withdraws the stale placeholder
  when there is one, and discards as `:not_an_eligible_source` when there is
  not — which is the ordinary case and still terminal, because no number of
  retries will make an Outlook target expand an RRULE.

  The route is the one a cancelled event already takes, and deliberately so:
  "this source may no longer have a placeholder here" is one question, and
  answering it in one place is what keeps the two answers from drifting.

  Everything else — a rate limit, an expired token, a timeout — is an
  `{:error, reason}` that Oban retries with backoff.

  ## Why the last failed attempt marks the target unhealthy

  A mirror write is best-effort by construction: it never fails the inbound
  sync that triggered it, and the reconcile sweep retries quietly. That is the
  right design and it has one consequence — a target calendar that refuses
  every write is completely silent to the organiser. The busy blocks simply
  stop appearing, and the first they hear of it is a double booking.

  The scheduled health probe cannot catch it either, because the probe is a
  *read*. An integration whose token was granted read-only, or whose calendar
  was made read-only downstream, passes every probe and fails every write. So a
  failure only the write path can observe is reported by the write path, into
  the health-check domain that already exists and already drives the hub badge
  — no second store, and no second breaker on top of
  `CalendarCircuitBreaker`.

  Only the *final* attempt marks. Everything before it is a blip that Oban's
  retry ladder exists to absorb, and marking on the first one would raise the
  badge for every timeout on every event.

  ## Eligibility is re-checked here

  The enqueue site already asked. Asking again is not redundancy: a job can sit
  in the queue while the event it names is edited, cancelled, or — the case that
  matters — written onto this very calendar as a mirror by the link pointing the
  other way. Checking only at enqueue time leaves a window in which a job
  enqueued for an ordinary event performs a write for what has since become a
  mirror, which is the loop this feature has to be free of.

  `unique` is keyed on `[:sync_link_id, :source_uid]` — not on the operation —
  and the enqueue site replaces the args of a job that has not started, so an
  upsert followed by a delete for the same event leaves one job carrying the
  delete rather than two racing to decide whether the placeholder survives.

  The uniqueness window is Oban's `:incomplete` group, which includes
  `:executing`, and the replace at the enqueue site names only the states where
  a job has *not* started. That pairing is deliberate, and the reasoning is
  worth keeping because both halves look wrong alone.

  A bare `replace: [:args]` expands across every state — `Oban.Job.put_replace/3`
  maps the fields over `states()` — so it rewrites a running job's args after
  `perform/1` has already read them. The write that arrives is then neither
  deferred nor applied; it is lost. Naming the pending states instead leaves the
  running job alone.

  Dropping `:executing` from uniqueness so the new write becomes its own job
  looks like the better fix and is not: Oban warns that an incomplete window
  missing `:executing` breaks uniqueness, and it is right — two jobs for one
  event could then run concurrently, racing to decide whether the placeholder
  survives, which is the thing uniqueness is here to prevent.

  What remains is a write raised while another is executing. Oban inserts
  *nothing* in that case — it matches the executing job as the conflict, finds
  no fields named for `:executing` in the `replace`, and returns the existing
  row untouched — so the newer intent is dropped rather than deferred. That was
  once written off here as a latency cost the reconcile sweep absorbs, and it is
  not: the sweep re-derives a `delete` from state and so does recover one, but a
  **cancellation correction cannot be re-derived from anything**. Google reports
  a cancelled occurrence in exactly one delta, and the sweep's `moved: :preserve`
  reads pending jobs — of which, after the drop, there are none carrying it.

  So the enqueue site answers the executing conflict instead of accepting it:
  `WriteBack` re-inserts the intent with `unique: false`, scheduled past the
  running job. Uniqueness still admits one writer at a time, and nothing is
  lost. See `WriteBack`'s moduledoc for why bypassing uniqueness is safe in
  exactly that one place.
  """
  use Oban.Worker,
    queue: :calendar_events,
    max_attempts: 5,
    priority: 3,
    unique: [
      keys: [:sync_link_id, :source_uid],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  @doc """
  How long to wait before retrying a failed write.

  Oban's default exhausts all five attempts inside about eighty seconds —
  17s, 20s, 24s, 31s. That is well judged for a dropped connection and
  exactly wrong for the failure this worker actually meets: a provider quota.
  Google meters per user over a rolling minute, so four retries inside ninety
  seconds mostly re-hit the same exhausted window, and a write is discarded
  permanently for a condition that was temporary by definition.

  It is not hypothetical. A backlog of mirrors reached Google at once, every
  job answered "Rate Limit Exceeded", and all of them exhausted their attempts
  and were discarded within the same minute.

  So each retry clears a full quota window and the run spans about twenty
  minutes rather than one. A discarded write is not lost — `SyncLinkReconcile`
  re-derives it from the mapping rows within half an hour — but a placeholder
  that arrives twenty minutes late is better than one that waits for a sweep,
  and far better than a burst of writes that all fail together.
  """
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    case attempt do
      1 -> 60
      2 -> 150
      3 -> 360
      4 -> 720
      _later_attempt -> 720
    end
  end

  # A snooze always clears Google's rolling-minute quota window, then spreads
  # over the following four minutes. Fifty jobs land across ~240 distinct
  # seconds rather than one, which is well under the per-second write quota
  # even with the queue's ten concurrent slots all busy.
  @snooze_floor_seconds 60
  @snooze_spread_seconds 240

  # Five writes a second against a documented ceiling of about ten. See
  # `budget_spent?/1` for why it sits below the published limit.
  @writes_per_window 5
  @write_window_ms 1_000

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.Capability
  alias Tymeslot.Integrations.Calendar.SyncLink.Eligibility
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine
  alias Tymeslot.Integrations.Calendar.SyncLink.UnmirrorableSeries
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Security.RateLimiter.Helpers, as: RateLimitHelpers

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt, max_attempts: max_attempts}) do
    %{
      "sync_link_id" => sync_link_id,
      "source_uid" => source_uid,
      "operation" => operation
    } = args

    case CalendarSyncLinkQueries.get(sync_link_id) do
      {:ok, link} ->
        link
        |> dispatch(source_uid, operation, attempt, Map.get(args, "moved", []))
        |> snooze_when_throttled()
        |> surface_exhausted_failure(link, attempt, max_attempts)

      {:error, :not_found} ->
        {:discard, :link_not_found}
    end
  end

  # The last attempt of a failing write is the only signal the organiser will
  # ever get that their target calendar is refusing mirrors — see the moduledoc.
  # A discard is deliberately excluded: it means the write was never attempted,
  # which says nothing about the target's health.
  # A rate limit is the one failure that is not this job's fault and not this
  # job's to survive: it says the *account* is over quota, which every other
  # job writing to the same calendar is about to discover too. Spending an
  # attempt on it means a backlog exhausts five attempts each and discards
  # every one — for a condition that clears within the minute. That is exactly
  # what happened on the first backfill: fifty queued mirrors, all refused, all
  # discarded together.
  #
  # `{:snooze, seconds}` reschedules without consuming an attempt, so a write
  # outlives a burst however long the burst lasts.
  #
  # The delay is jittered because the jobs are refused within the same second
  # or two. A fixed snooze would reschedule the whole backlog onto one instant
  # and rebuild the burst that caused the refusal; spreading them over several
  # minutes is what actually drains the queue against a per-second quota.
  defp snooze_when_throttled({:error, :rate_limited}) do
    {:snooze, @snooze_floor_seconds + :rand.uniform(@snooze_spread_seconds)}
  end

  defp snooze_when_throttled(outcome), do: outcome

  # The provider refused the request as written, and will refuse it identically
  # on every retry. Discarding costs one placeholder; retrying costs five
  # attempts across twenty minutes and then the sweep's re-derivation, forever.
  #
  # It also must not mark the target unhealthy: the badge reports a target that
  # cannot receive writes, and a payload the provider dislikes says nothing
  # about the target. Matched before the exhaustion clause for that reason.
  defp surface_exhausted_failure({:error, :invalid_request}, _link, _attempt, _max_attempts),
    do: {:discard, :invalid_request}

  defp surface_exhausted_failure({:error, _reason} = outcome, link, attempt, max_attempts)
       when attempt >= max_attempts do
    HealthCheck.mark_write_failure(:calendar, link.target_integration_id, link.user_id)
    outcome
  end

  defp surface_exhausted_failure(outcome, _link, _attempt, _max_attempts), do: outcome

  # A withdrawal outlives the pause that a teardown caused. `Teardown` disables
  # the link *before* deleting its placeholders, so a provider that refused a
  # delete leaves a disabled link still holding `pending_delete` rows — and
  # `SyncLinkReconcileWorker.finish_withdrawals/1` re-enqueues exactly these
  # jobs to finish it. Discarding them is what strands the placeholder for
  # good: nothing else revisits a `pending_delete` mapping, so the block stays
  # on the organiser's calendar and the row stays in the table, while the sweep
  # re-enqueues a job that can never land.
  #
  # A user-paused link reaches this clause too, and should: pausing leaves
  # existing placeholders standing, and no withdrawal is enqueued for one.
  defp dispatch(
         %CalendarSyncLinkSchema{enabled: false} = link,
         source_uid,
         "delete",
         attempt,
         _moved
       ),
       do: run(link, source_uid, "delete", attempt, [])

  # Anything else a paused link is asked to write, it does not. Matched before
  # the target is even looked at: whether the target could receive a write is
  # irrelevant once the organiser has said not to send one.
  defp dispatch(
         %CalendarSyncLinkSchema{enabled: false},
         _source_uid,
         _operation,
         _attempt,
         _moved
       ),
       do: {:discard, :link_disabled}

  defp dispatch(%CalendarSyncLinkSchema{} = link, source_uid, operation, attempt, moved) do
    cond do
      read_only_target?(link) ->
        {:discard, :target_is_read_only}

      # Asked before the write rather than learned from its refusal. The snooze
      # below survives a rate limit; this stops the burst that causes one from
      # ever leaving the machine.
      budget_spent?(link) ->
        {:error, :rate_limited}

      true ->
        run(link, source_uid, operation, attempt, moved)
    end
  end

  # A per-account budget for provider writes.
  #
  # The queue runs ten jobs at once and nine other workers share it, so pacing
  # by queue concurrency would throttle bookings and inbound syncs to fix a
  # background feature. The budget is charged here instead: it meters exactly
  # this traffic and nothing else.
  #
  # Keyed on the *target integration* because that is the granularity Google
  # enforces at — a per-user quota on the account being written to. Two
  # organisers backfilling at once must not share a budget; two links pointing
  # at one calendar must.
  #
  # Backed by the same ETS sliding window as the dashboard limiter, so the
  # count is shared across the queue's workers rather than per-process. It is
  # per-machine, which is exact here: `fly.toml` fixes this app at one machine
  # because a volume cannot be shared. A second machine would need a shared
  # backend, and this comment is the reminder.
  #
  # Deliberately under Google's documented ceiling. The published limit is
  # about ten writes a second per user, and a limit set at the ceiling is one
  # that is regularly exceeded — the window is a local approximation of a
  # counter Google keeps elsewhere, and requests in flight are not yet counted.
  defp budget_spent?(%CalendarSyncLinkSchema{target_integration_id: target_id}) do
    RateLimitHelpers.check_rate_limit(
      "calendar_mirror_write:#{target_id}",
      @writes_per_window,
      @write_window_ms
    ) == {:error, :rate_limited}
  end

  # `target_integration` is preloaded by `CalendarSyncLinkQueries.get/1`. A link
  # whose target could not be loaded is treated as read-only rather than
  # written to blind — the failure mode of refusing a writable target is a
  # missing busy block, and of writing to an unknown one is an event on a
  # calendar nobody asked for.
  defp read_only_target?(%{target_integration: %{provider: provider}}),
    do: not Capability.supports?(provider, :mirror_target)

  # The fallback stays a separate head rather than folding into the capability
  # question: there is no provider to ask about here, and the answer is not
  # "this provider cannot receive writes" but "nothing established that it can".
  defp read_only_target?(_link), do: true

  # The attempt travels into the domain for one decision only: whether a
  # provider failure is the end of the road, and so a conflict worth recording,
  # or a write Oban is about to try again. That is the worker's knowledge — it
  # owns the *when* — and the engine cannot obtain it any other way.
  defp run(link, source_uid, "delete", attempt, _moved),
    do: Engine.unmirror(link, source_uid, link.user_id, attempt: attempt)

  defp run(link, source_uid, "upsert", attempt, moved) do
    case ProviderCalendarEventQueries.get_by_uid(link.source_integration_id, source_uid) do
      {:ok, event} ->
        upsert(link, event, source_uid, attempt, moved)

      # The source has vanished from the cache. If it left a placeholder behind,
      # that placeholder is now blocking time for an event that no longer
      # exists, so it is withdrawn rather than left; if it did not, there is
      # nothing this job can ever do.
      {:error, :not_found} ->
        unmirror_or_discard(link, source_uid, :source_not_cached, attempt)
    end
  end

  defp upsert(link, event, source_uid, attempt, moved) do
    if Eligibility.mirror_source?(
         event,
         mirror_set(link),
         target_provider(link),
         source_provider(link)
       ) do
      Engine.mirror(link, event, link.user_id, attempt: attempt, moved: moved)
    else
      # Ineligible now, but it may have been eligible when the placeholder was
      # written — a cancelled meeting, an event switched to free, an event this
      # link's counterpart has since mirrored onto the source calendar, or a
      # recurring series on a link that cannot carry one. Whatever the
      # reason, the placeholder must stop blocking time.
      #
      # One of those reasons gets a voice before the discard. A series refused
      # because an end of this link cannot handle it is not a transient state
      # the organiser will see resolve: nothing retries it, no placeholder is
      # ever written, and the discard reason below reaches Oban and nobody
      # else. `UnmirrorableSeries` decides for itself whether this is that case
      # and whether it has already been said, so an ordinary refusal passes
      # through here recording nothing.
      UnmirrorableSeries.record(link, event)

      unmirror_or_discard(link, source_uid, :not_an_eligible_source, attempt)
    end
  end

  # The link's target provider, which `Eligibility` needs for exactly one
  # decision: whether a recurring source may be mirrored here. Preloaded by
  # `CalendarSyncLinkQueries.get/1`; `nil` for a link whose association could
  # not be loaded, which `Capability` answers as an unrecognised provider and so
  # refuses a series — the same conservative direction `read_only_target?/1`
  # takes for the same shape.
  defp target_provider(%{target_integration: %{provider: provider}}), do: provider
  defp target_provider(_link), do: nil

  # The other half of the recurrence question, and the half whose absence was a
  # silent discard. `Eligibility` needs it to ask whether this source's series
  # master can be fetched at all — an Outlook or CalDAV source has no lookup
  # wired up, so a series from one could never be described however capable the
  # target was. Preloaded by `CalendarSyncLinkQueries.get/1`; `nil` for a link
  # whose association could not be loaded, which `Capability` refuses like any
  # unrecognised provider.
  defp source_provider(%{source_integration: %{provider: provider}}), do: provider
  defp source_provider(_link), do: nil

  defp unmirror_or_discard(link, source_uid, reason, attempt) do
    case CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, source_uid) do
      {:ok, _mirror} -> Engine.unmirror(link, source_uid, link.user_id, attempt: attempt)
      {:error, :not_found} -> {:discard, reason}
    end
  end

  # Scoped to the source integration, because that is the only calendar whose
  # events this link reads. Asking for every mirror in the installation would
  # answer the same question at a cost proportional to the whole table.
  defp mirror_set(link),
    do: CalendarSyncMirrorQueries.mirror_uids_for_integrations([link.source_integration_id])
end
