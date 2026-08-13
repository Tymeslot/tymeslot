defmodule Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries do
  @moduledoc """
  Data access for `calendar_sync_mirrors`. All `Repo` calls for the mirror
  mappings live here (RepoCallBoundary).

  Two readers, pulling in opposite directions:

  `get_by_link_and_source_uid/2` is the engine's forward lookup — from a link
  and the source event it is processing to the placeholder already written, or
  nothing. It rides the unique index on `[sync_link_id, source_uid]`.

  `mirror_uids_for_integrations/1` is the calendar grid's backward lookup —
  from the integrations whose events it is about to draw to the UIDs among them
  that are mirrors and must be hidden. It rides
  `calendar_sync_mirrors_target_uid_index` on
  `[target_integration_id, target_uid]`, which exists solely for this question:
  without it the grid falls to a sequential scan of every mirror row in the
  installation, on every render, and the grid re-renders on navigation, on live
  cache updates, and on every appearance change.

  The backward lookup returns a `MapSet` rather than a list because its caller
  is a per-event membership test inside a render loop. Handing back a list
  would turn one filter pass into a scan per event.
  """
  import Ecto.Query

  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema
  alias Tymeslot.Repo

  @doc """
  The mapping this link holds for one source event, if it has mirrored it.
  """
  @spec get_by_link_and_source_uid(integer(), String.t()) ::
          {:ok, CalendarSyncMirrorSchema.t()} | {:error, :not_found}
  def get_by_link_and_source_uid(sync_link_id, source_uid)
      when is_integer(sync_link_id) and is_binary(source_uid) do
    case Repo.get_by(CalendarSyncMirrorSchema,
           sync_link_id: sync_link_id,
           source_uid: source_uid
         ) do
      nil -> {:error, :not_found}
      mirror -> {:ok, mirror}
    end
  end

  def get_by_link_and_source_uid(_sync_link_id, _source_uid), do: {:error, :not_found}

  @doc """
  Every mirror living on the given target integrations, as a set of
  `{integration_id, target_uid}` pairs.

  Measured at 100,000 mirror rows across 20 target integrations, selecting
  five of them: a Bitmap Index Scan on
  `[target_integration_id, target_uid]` feeding a Bitmap Heap Scan, ~4.9 ms.
  Not an index-only scan — the visibility map on a table this write-heavy is
  rarely all-visible, so the heap is still read — but the index is what keeps
  the row count proportional to the integrations asked for rather than to
  every mirror in the installation.

  `pending_delete` mirrors are included deliberately. Their placeholder is
  still on the provider until it confirms the delete, so it is still in the
  event cache and still needs hiding; dropping it from this set would make the
  mirror flash into the organiser's grid for exactly as long as the teardown
  takes.
  """
  @spec mirror_uids_for_integrations([integer()]) :: MapSet.t({integer(), String.t()})
  def mirror_uids_for_integrations([]), do: MapSet.new()

  def mirror_uids_for_integrations(integration_ids) when is_list(integration_ids) do
    CalendarSyncMirrorSchema
    |> where([m], m.target_integration_id in ^integration_ids)
    |> select([m], {m.target_integration_id, m.target_uid})
    |> Repo.all()
    |> MapSet.new()
  end
end
