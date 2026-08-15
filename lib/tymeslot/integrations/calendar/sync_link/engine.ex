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
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.SyncLink.MirrorPayload

  @uid_prefix "tymeslot-mirror-"

  @typedoc "What the worker maps straight onto Oban's return vocabulary."
  @type result :: :ok | {:error, term()} | {:discard, term()}

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
  @spec mirror(CalendarSyncLinkSchema.t(), map(), integer()) :: result()
  def mirror(%CalendarSyncLinkSchema{} = link, source_event, user_id)
      when is_integer(user_id) do
    source_uid = source_event.uid
    target_uid = target_uid_for(link.id, source_uid)

    case CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, source_uid) do
      {:ok, mirror} -> update_mirror(link, mirror, source_event, target_uid, user_id)
      {:error, :not_found} -> create_mirror(link, source_event, target_uid, user_id)
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
  @spec unmirror(CalendarSyncLinkSchema.t(), String.t(), integer()) :: result()
  def unmirror(%CalendarSyncLinkSchema{} = link, source_uid, user_id)
      when is_binary(source_uid) and is_integer(user_id) do
    case CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, source_uid) do
      {:error, :not_found} -> :ok
      {:ok, mirror} -> delete_mirror(link, mirror, user_id)
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

  defp create_mirror(link, source_event, target_uid, user_id) do
    payload = payload_for(link, source_event, target_uid)

    case CalendarEvents.create_event(payload, {link.target_integration_id, user_id}) do
      {:ok, created} ->
        persist_or_compensate(link, source_event, target_uid, created, user_id)

      {:error, reason} ->
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

  defp update_mirror(link, mirror, source_event, target_uid, user_id) do
    payload = payload_for(link, source_event, target_uid)

    case CalendarEvents.update_event(target_uid, payload, {link.target_integration_id, user_id}) do
      :ok ->
        mark(mirror, %{
          state: "active",
          last_synced_at: DateTime.utc_now(),
          source_updated_at: Map.get(source_event, :provider_updated_at),
          source_etag: Map.get(source_event, :etag)
        })

        :ok

      {:error, reason} ->
        # The placeholder on the target is now out of step with its source, and
        # only the row records that. Marking it here is what lets the reconcile
        # sweep find it after Oban has exhausted its attempts.
        mark(mirror, %{state: "failed"})
        {:error, reason}
    end
  end

  # --- Delete ---

  defp delete_mirror(link, mirror, user_id) do
    case CalendarEvents.delete_event(mirror.target_uid, {link.target_integration_id, user_id}) do
      :ok -> drop_mapping(mirror)
      # Already gone on the provider. The mapping is the only thing left, and
      # keeping it would make the sweep retry a delete that can never succeed.
      {:error, :not_found} -> drop_mapping(mirror)
      {:error, reason} -> mark_pending_delete(mirror, reason)
    end
  end

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
