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

  @type write_result ::
          {:ok, CalendarSyncMirrorSchema.t()} | {:error, Ecto.Changeset.t()}

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

  @doc """
  Every mapping this link holds, in whatever state.

  The reconcile sweep's half of the diff. `pending_delete` and `failed` rows are
  returned alongside `active` ones on purpose: those are precisely the mappings
  whose last write did not land, and a sweep that could not see them would leave
  a half-torn-down placeholder on the target forever.
  """
  @spec list_for_link(integer()) :: [CalendarSyncMirrorSchema.t()]
  def list_for_link(sync_link_id) when is_integer(sync_link_id) do
    CalendarSyncMirrorSchema
    |> where([m], m.sync_link_id == ^sync_link_id)
    |> order_by([m], asc: m.id)
    |> Repo.all()
  end

  @doc """
  Records a placeholder the engine has just written onto a target.

  Returning the changeset error rather than raising is what makes orphan
  compensation possible: the engine sees the failure, deletes the provider event
  it created a moment ago, and lets the retry start from nothing.
  """
  @spec create(map()) :: write_result()
  def create(attrs) do
    %CalendarSyncMirrorSchema{}
    |> CalendarSyncMirrorSchema.changeset(attrs)
    |> Repo.insert()
  end

  @spec update(CalendarSyncMirrorSchema.t(), map()) :: write_result()
  def update(%CalendarSyncMirrorSchema{} = mirror, attrs) do
    mirror
    |> CalendarSyncMirrorSchema.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Drops the mapping once the provider has confirmed the placeholder is gone.

  Deleting the row is what ends the mirror's life, so it must not happen before
  the provider delete succeeds: the row holds the only record of which provider
  event to remove, and losing it strands the placeholder on the target with
  nothing owning it. `pending_delete` is the state for the interval between the
  source disappearing and the provider confirming.
  """
  @spec delete(CalendarSyncMirrorSchema.t()) :: write_result()
  def delete(%CalendarSyncMirrorSchema{} = mirror), do: Repo.delete(mirror)
end
