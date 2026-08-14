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
  - `:link_disabled` — the link is paused. Pausing deliberately leaves existing
    placeholders alone, so there is nothing to do and nothing to undo.
  - `:target_is_read_only` — a subscription feed. `create_event` returns
    `{:error, :read_only}` for these *always*. The changeset already refuses
    such a target at configuration time; this catches the link configured
    before its target was reconnected as a subscription. It is matched on the
    function head, ahead of every other consideration, so a hopeless write
    never reaches the provider at all.
  - `:source_not_cached` — the source event is gone from the cache and there is
    no mapping to withdraw either. Nothing to mirror and nothing to clean up.
  - `:not_an_eligible_source` — the event fails `Eligibility.mirror_source?/2`:
    it is itself a mirror, recurring, transparent, or cancelled. The one nuance
    is that an event which *became* ineligible after having been mirrored is not
    a discard — its placeholder is withdrawn first, because a source that has
    turned transparent or been cancelled must stop blocking time on the target.

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
  with `replace: [:args]` at the enqueue site, so an upsert followed by a delete
  for the same event leaves one job carrying the delete rather than two racing
  to decide whether the placeholder survives.
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

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.Capability
  alias Tymeslot.Integrations.Calendar.SyncLink.Eligibility
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine
  alias Tymeslot.Integrations.HealthCheck

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
        |> dispatch(source_uid, operation, attempt)
        |> surface_exhausted_failure(link, attempt, max_attempts)

      {:error, :not_found} ->
        {:discard, :link_not_found}
    end
  end

  # The last attempt of a failing write is the only signal the organiser will
  # ever get that their target calendar is refusing mirrors — see the moduledoc.
  # A discard is deliberately excluded: it means the write was never attempted,
  # which says nothing about the target's health.
  defp surface_exhausted_failure({:error, _reason} = outcome, link, attempt, max_attempts)
       when attempt >= max_attempts do
    HealthCheck.mark_write_failure(:calendar, link.target_integration_id, link.user_id)
    outcome
  end

  defp surface_exhausted_failure(outcome, _link, _attempt, _max_attempts), do: outcome

  # A paused link writes nothing, in either direction. Matched before the target
  # is even looked at: whether the target could receive a write is irrelevant
  # once the organiser has said not to send one.
  defp dispatch(%CalendarSyncLinkSchema{enabled: false}, _source_uid, _operation, _attempt),
    do: {:discard, :link_disabled}

  defp dispatch(%CalendarSyncLinkSchema{} = link, source_uid, operation, attempt) do
    if read_only_target?(link) do
      {:discard, :target_is_read_only}
    else
      run(link, source_uid, operation, attempt)
    end
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
  defp run(link, source_uid, "delete", attempt),
    do: Engine.unmirror(link, source_uid, link.user_id, attempt: attempt)

  defp run(link, source_uid, "upsert", attempt) do
    case ProviderCalendarEventQueries.get_by_uid(link.source_integration_id, source_uid) do
      {:ok, event} ->
        upsert(link, event, source_uid, attempt)

      # The source has vanished from the cache. If it left a placeholder behind,
      # that placeholder is now blocking time for an event that no longer
      # exists, so it is withdrawn rather than left; if it did not, there is
      # nothing this job can ever do.
      {:error, :not_found} ->
        unmirror_or_discard(link, source_uid, :source_not_cached, attempt)
    end
  end

  defp upsert(link, event, source_uid, attempt) do
    if Eligibility.mirror_source?(event, mirror_set(link)) do
      Engine.mirror(link, event, link.user_id, attempt: attempt)
    else
      # Ineligible now, but it may have been eligible when the placeholder was
      # written — a cancelled meeting, an event switched to free, or an event
      # this link's counterpart has since mirrored onto the source calendar.
      # Whatever the reason, the placeholder must stop blocking time.
      unmirror_or_discard(link, source_uid, :not_an_eligible_source, attempt)
    end
  end

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
