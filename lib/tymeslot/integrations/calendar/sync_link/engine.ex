defmodule Tymeslot.Integrations.Calendar.SyncLink.Engine do
  @moduledoc """
  Writes one placeholder onto a target calendar and keeps the mapping row that
  records where it went.

  This is the *what*, in the split the codebase uses throughout: the worker owns
  the when — dispatch, retries, backoff, and turning outcomes into Oban's
  vocabulary — while everything here is the domain operation, callable outside a
  job. The return contract is `:ok | {:error, term()} | {:discard, term()}` so
  the worker can pass it straight through, but the meaning of the three is
  decided here, where the reason is known.

  ## Deterministic target UIDs

  A placeholder's UID on the target is derived from `{sync_link_id,
  source_uid}`, never generated randomly. CalDAV's PUT is idempotent on a
  caller-supplied UID, so a write repeated after a lost response converges on
  one event instead of leaving two; and the mapping row, if it is ever lost,
  can be rebuilt by recomputing the UID rather than by guessing which event on
  the target was ours.

  Both halves go into the hash. Without `sync_link_id` two links mirroring the
  same source event onto two calendars would derive the same UID, which is
  harmless while the targets differ and a collision the moment they do not.

  ## Orphan compensation

  The hazard `CalendarEventSync.persist_or_compensate/3` documents applies here
  unchanged. If the provider create succeeds and the mapping insert then fails,
  the placeholder exists on the target with nothing pointing at it. The Oban
  retry finds no mapping, treats the event as unmirrored, and creates a second
  placeholder — and Google and Outlook, which assign event ids server-side,
  cannot detect that they already hold the first. Two busy blocks then sit on
  the target, and only one of them will ever be updated or deleted.

  So a failed persist is followed by a delete of the event just created, before
  the error is surfaced, leaving the retry a clean slate. The compensating
  delete is best-effort: if it also fails, the *original* error is still what
  the caller sees, because that is the failure the retry needs to act on. The
  orphan is then logged at warning, which is the only trace it will leave.

  ## Deleting

  `unmirror/3` is deliberately asymmetric with `mirror/3`. The provider delete
  goes first and the mapping row is dropped only once it succeeds, because the
  row holds the `target_uid` that identifies the placeholder — deleting it first
  would strand a busy block on the organiser's calendar that nothing owns and
  nothing will ever clean up. A delete that fails leaves the row behind in
  `pending_delete`, which is exactly the state the reconcile sweep looks for.

  ## Conflicts, and why they are recorded here

  A mirror is not independently editable: whatever the organiser does to a
  placeholder on the target, the source overwrites it on the next pass, and a
  source deleted while its placeholder was edited takes the placeholder with it.
  Both are defensible resolutions, and both destroy work without saying so —
  which is why each leaves a row in `calendar_sync_conflicts`. The evidence for
  the decision (the etags compared, the timestamps, the provider error) exists
  only inside the branch that made it, so it is recorded there rather than
  reconstructed afterwards from state that has since been overwritten.

  `SyncLink.ConflictLog` owns the classification; this module owns when to ask
  it. The split matters because the same evidence is read on three paths —
  update, delete, and terminal failure — and three independent readings of it is
  how one divergence ends up appended twice under two names.

  ## The attempt count

  `write_failed` is the one conflict that turns on something the domain cannot
  see: whether Oban will try again. A retryable error is a write still in
  flight, not a resolution, and recording each attempt would fill the history
  with rows for writes that succeeded seconds later. So the caller passes its
  attempt number — exactly as `Meetings.CalendarEventSync` takes one, for the
  same purpose — and only the final attempt records a failure.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.ConflictLog
  alias Tymeslot.Integrations.Calendar.SyncLink.MirrorPayload

  @uid_prefix "tymeslot-mirror-"

  # Matches `SyncLinkWriteBackWorker`'s `max_attempts`. A caller passing no
  # attempt is not running under Oban — a sweep, a console, a test — and has no
  # retry pending, so its failure is terminal where it stands.
  @final_attempt 5

  @typedoc "What the worker maps straight onto Oban's return vocabulary."
  @type result :: :ok | {:error, term()} | {:discard, term()}

  @typedoc """
  `:attempt` is the caller's Oban attempt number. It decides only whether a
  provider failure is recorded as a resolved conflict or left alone as a write
  still being retried.
  """
  @type opts :: [attempt: pos_integer()]

  @doc """
  Creates or updates the placeholder for one source event on this link's target.

  Whether it creates or updates is decided by the mapping row, not by asking the
  provider: the row is the record of what Tymeslot has written, and a lookup per
  event against three provider APIs would cost a round trip per event on every
  sync.

  Eligibility is *not* re-checked here. `Eligibility.mirror_source?/2` is the
  single gate and every caller passes through it first; repeating the check with
  a mirror set this module would have to fetch itself would make it two gates
  that can disagree.
  """
  @spec mirror(CalendarSyncLinkSchema.t(), map(), integer(), opts()) :: result()
  def mirror(%CalendarSyncLinkSchema{} = link, source_event, user_id, opts \\ [])
      when is_integer(user_id) and is_list(opts) do
    source_uid = source_event.uid
    target_uid = target_uid_for(link.id, source_uid)
    final? = final_attempt?(opts)

    case CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, source_uid) do
      {:ok, mirror} ->
        update_mirror(link, mirror, source_event, target_uid, user_id, final?)

      {:error, :not_found} ->
        create_mirror(link, source_event, target_uid, user_id, final?)
    end
  end

  @doc """
  Withdraws the placeholder for a source event that is gone, or that has stopped
  being an eligible source.

  A source that was never mirrored is `:ok` rather than an error — the sweep
  and the sync path both call this without first establishing that a mapping
  exists, and "there is nothing to withdraw" is the same outcome as having
  withdrawn it.
  """
  @spec unmirror(CalendarSyncLinkSchema.t(), String.t(), integer(), opts()) :: result()
  def unmirror(%CalendarSyncLinkSchema{} = link, source_uid, user_id, opts \\ [])
      when is_binary(source_uid) and is_integer(user_id) and is_list(opts) do
    case CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, source_uid) do
      {:error, :not_found} -> :ok
      {:ok, mirror} -> delete_mirror(link, mirror, user_id, final_attempt?(opts))
    end
  end

  @doc """
  The UID a placeholder carries on the target, derived from the link and the
  source event.

  Deterministic and collision-resistant: the same pair always yields the same
  UID, and a source UID of any length or character set yields one that is valid
  everywhere. Google's own `uuid_to_google_event_id/1` re-hashes anything that
  is not base32hex, so the readable prefix here is for the organiser looking at
  a raw iCalendar body, not for the provider.
  """
  @spec target_uid_for(integer(), String.t()) :: String.t()
  def target_uid_for(sync_link_id, source_uid)
      when is_integer(sync_link_id) and is_binary(source_uid) do
    digest =
      :sha256
      |> :crypto.hash("#{sync_link_id}\0#{source_uid}")
      |> Base.encode32(case: :lower, padding: false)
      |> String.slice(0, 32)

    @uid_prefix <> digest
  end

  # --- Create ---

  defp create_mirror(link, source_event, target_uid, user_id, final?) do
    payload = payload_for(link, source_event, target_uid)

    case CalendarEvents.create_event(payload, {link.target_integration_id, user_id}) do
      {:ok, created} ->
        persist_or_compensate(link, source_event, target_uid, created, user_id)

      {:error, reason} ->
        record_write_failure(link, source_event.uid, :create, reason, final?)
        {:error, reason}
    end
  end

  # See the moduledoc. The provider event exists from this point on; if the row
  # recording it cannot be written, the event has to go before the error does.
  defp persist_or_compensate(link, source_event, target_uid, created, user_id) do
    attrs = %{
      sync_link_id: link.id,
      source_uid: source_event.uid,
      target_integration_id: link.target_integration_id,
      target_uid: target_uid,
      target_provider_event_id: provider_event_id(created),
      target_etag: observed_target_etag(link.target_integration_id, target_uid),
      source_updated_at: Map.get(source_event, :provider_updated_at),
      source_etag: Map.get(source_event, :etag),
      last_synced_at: DateTime.utc_now(),
      state: "active"
    }

    case CalendarSyncMirrorQueries.create(attrs) do
      {:ok, _mirror} ->
        :ok

      {:error, reason} ->
        compensate_orphaned_mirror(link, target_uid, user_id)
        {:error, reason}
    end
  end

  # Best-effort. The original persistence failure is what the caller sees either
  # way; this only decides whether the retry starts clean or starts with a
  # duplicate waiting for it.
  defp compensate_orphaned_mirror(link, target_uid, user_id) do
    Logger.warning(
      "Mirror mapping persistence failed after create; deleting orphaned placeholder to keep the retry idempotent",
      sync_link_id: link.id,
      target_integration_id: link.target_integration_id,
      target_uid: target_uid
    )

    case CalendarEvents.delete_event(target_uid, {link.target_integration_id, user_id}) do
      :ok ->
        :ok

      {:error, :not_found} ->
        :ok

      other ->
        Logger.error("Failed to delete orphaned mirror placeholder after persistence failure",
          sync_link_id: link.id,
          target_integration_id: link.target_integration_id,
          target_uid: target_uid,
          result: inspect(other)
        )

        :ok
    end
  end

  # --- Update ---

  defp update_mirror(link, mirror, source_event, target_uid, user_id, final?) do
    payload = payload_for(link, source_event, target_uid)

    case CalendarEvents.update_event(target_uid, payload, {link.target_integration_id, user_id}) do
      :ok ->
        # Recorded only once the overwrite has actually landed. A conflict is a
        # resolution, and a write that failed resolved nothing — logging before
        # the call would append a row per retry for a divergence still
        # outstanding, and the retry that finally succeeds would append one
        # more. The evidence survives the write either way: the placeholder's
        # cached state is a projection of the target's own sync, which this
        # write does not touch.
        ConflictLog.record_overwrite(mirror, source_event)

        mark(mirror, %{
          state: "active",
          last_synced_at: DateTime.utc_now(),
          target_etag: observed_target_etag(link.target_integration_id, target_uid),
          source_updated_at: Map.get(source_event, :provider_updated_at),
          source_etag: Map.get(source_event, :etag)
        })

        :ok

      {:error, reason} ->
        # The placeholder on the target is now out of step with its source, and
        # only the row records that. Marking it here is what lets the reconcile
        # sweep find it after Oban has exhausted its attempts.
        mark(mirror, %{state: "failed"})
        record_write_failure(link, mirror.source_uid, :update, reason, final?)
        {:error, reason}
    end
  end

  # --- Delete ---

  defp delete_mirror(link, mirror, user_id, final?) do
    mirror = consume_delete_race(mirror)

    case CalendarEvents.delete_event(mirror.target_uid, {link.target_integration_id, user_id}) do
      :ok ->
        drop_mapping(mirror)

      # Already gone on the provider. The mapping is the only thing left, and
      # keeping it would make the sweep retry a delete that can never succeed.
      {:error, :not_found} ->
        drop_mapping(mirror)

      {:error, reason} ->
        record_write_failure(link, mirror.source_uid, :delete, reason, final?)
        mark_pending_delete(mirror, reason)
    end
  end

  # The race is recorded before the provider delete, because a delete that fails
  # leaves the mapping in `pending_delete` for the sweep to retry — and the
  # evidence, the placeholder's cached etag, is still there for the retry to
  # find. Recording it on the first pass and then clearing the baseline it was
  # read from is what makes one race one row: the retry has nothing left to
  # compare, and there was never a second race to describe.
  defp consume_delete_race(mirror) do
    case ConflictLog.record_delete_race(mirror) do
      :recorded -> mark(mirror, %{target_etag: nil})
      :nothing_to_record -> mirror
    end
  end

  # The etag the target's own sync currently holds for the placeholder, taken as
  # the baseline a later direct edit is measured against. Read from the cache
  # rather than from the write's response because no provider returns one
  # uniformly there — CalDAV echoes the payload it PUT, Google and Outlook their
  # own event body — while the target's inbound sync stores an etag for every
  # event it fetches, this one included.
  defp observed_target_etag(target_integration_id, target_uid) do
    case ProviderCalendarEventQueries.get_by_uid(target_integration_id, target_uid) do
      {:ok, %{etag: etag}} -> etag
      {:error, :not_found} -> nil
    end
  end

  # Only the last attempt records a failure; see the moduledoc. A caller that
  # names no attempt has no retry pending and is treated as final.
  defp final_attempt?(opts), do: Keyword.get(opts, :attempt, @final_attempt) >= @final_attempt

  defp record_write_failure(_link, _source_uid, _operation, _reason, false), do: :ok

  defp record_write_failure(link, source_uid, operation, reason, true),
    do: ConflictLog.record_write_failure(link.id, source_uid, operation, reason)

  defp drop_mapping(mirror) do
    case CalendarSyncMirrorQueries.delete(mirror) do
      {:ok, _deleted} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_pending_delete(mirror, reason) do
    mark(mirror, %{state: "pending_delete"})
    {:error, reason}
  end

  # Bookkeeping that must not turn a successful provider write into a failure:
  # the placeholder is already correct on the target, and the row falling behind
  # is a state the sweep reconciles. Logged so it is not invisible.
  defp mark(%CalendarSyncMirrorSchema{} = mirror, attrs) do
    case CalendarSyncMirrorQueries.update(mirror, attrs) do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        Logger.warning("Failed to update mirror mapping state",
          sync_link_id: mirror.sync_link_id,
          source_uid: mirror.source_uid,
          reason: inspect(changeset.errors)
        )

        mirror
    end
  end

  # --- Payload ---

  # The privacy tier decides the content; the link decides where it lands.
  # Google and Outlook honour `:calendar_id`, the CalDAV family ignores it and
  # always writes to the primary path — which is why the schema clears
  # `target_calendar_id` for a CalDAV target rather than storing a preference
  # the write cannot honour.
  defp payload_for(link, source_event, target_uid) do
    payload = MirrorPayload.build(source_event, target_uid)

    case link.target_calendar_id do
      nil -> payload
      calendar_id -> Map.put(payload, :calendar_id, calendar_id)
    end
  end

  # `create_event/2` promises `{:ok, map()}`, but not one shape of map: the
  # CalDAV family answers with the payload it PUT (carrying the UID the caller
  # supplied), while Google and Outlook echo the provider's own response, whose
  # id is server-assigned and lives under `"id"`. `nil` is an acceptable answer
  # — the mapping is still written, keyed on the deterministic `target_uid`,
  # which is what every subsequent update and delete addresses. The provider id
  # is recorded for diagnosis and for the reconcile sweep, not for addressing.
  defp provider_event_id(%{provider_event_id: id}) when is_binary(id), do: id
  defp provider_event_id(%{"id" => id}) when is_binary(id), do: id
  defp provider_event_id(%{id: id}) when is_binary(id), do: id
  defp provider_event_id(_other), do: nil
end
