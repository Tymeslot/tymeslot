defmodule Tymeslot.Integrations.Calendar.SyncLink.OrphanCompensation do
  @moduledoc """
  Deletes a placeholder that was written to a target but never recorded, so the
  retry that follows starts from a clean calendar.

  ## The hazard

  Writing a mirror is two steps that can fail independently: the provider create
  succeeds, and the mapping row insert then does not. The placeholder exists on
  the target with nothing pointing at it. The Oban retry finds no mapping, reads
  the source as unmirrored, and creates a **second** placeholder — and Google
  and Outlook assign event ids server-side, so neither can tell it already holds
  the first. Two busy blocks then sit on the organiser's calendar, and only one
  of them will ever be updated or withdrawn.

  This is the same hazard `Meetings.CalendarEventSync.persist_or_compensate/3`
  documents, in the same shape, and it is compensated the same way: undo the
  provider write before surfacing the persistence error.

  ## Why it is best-effort, and why the original error still wins

  If the compensating delete also fails, the caller still sees the **original**
  persistence failure, because that is the one the retry needs to act on. A
  compensation error would replace a description of what went wrong with a
  description of a cleanup that went wrong afterwards.

  The orphan is then logged at error level, which is the only trace it leaves —
  `SyncLink.OrphanScan` is what finds it later.

  A provider `:not_found` is success, not failure: the placeholder is not there,
  which is precisely the state being aimed at.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents

  @doc """
  Deletes the just-created placeholder named by `target_uid`.

  Always returns `:ok`. The caller surfaces its own error regardless — see the
  moduledoc.
  """
  @spec delete_orphan(struct(), String.t(), integer(), keyword()) :: :ok
  def delete_orphan(link, target_uid, user_id, calendar_opts) do
    Logger.warning(
      "Mirror mapping persistence failed after create; deleting orphaned placeholder to keep the retry idempotent",
      sync_link_id: link.id,
      target_integration_id: link.target_integration_id,
      target_uid: target_uid
    )

    case CalendarEvents.delete_event(
           target_uid,
           {link.target_integration_id, user_id},
           calendar_opts
         ) do
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
end
