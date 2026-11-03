defmodule Tymeslot.MeetingTypes.OfferedTimeQueries do
  @moduledoc """
  Database access for one-to-one meeting types' offered times
  (`Tymeslot.MeetingTypes.OfferedTimes`).
  """
  import Ecto.Query, warn: false

  alias Tymeslot.MeetingTypes.OfferedTimeSchema
  alias Tymeslot.Repo

  @doc "The type's offered times starting after `since` (every one for nil), in start order."
  @spec list_for_type(integer(), DateTime.t() | nil) :: [OfferedTimeSchema.t()]
  def list_for_type(meeting_type_id, since \\ nil) do
    meeting_type_id
    |> for_types_after(since)
    |> Repo.all()
  end

  @doc "`list_for_type/2` for several types in one query, in start order."
  @spec list_for_types([integer()], DateTime.t() | nil) :: [OfferedTimeSchema.t()]
  def list_for_types([], _since), do: []

  def list_for_types(meeting_type_ids, since) do
    meeting_type_ids
    |> for_types_after(since)
    |> Repo.all()
  end

  @spec get_for_type(integer(), integer()) :: OfferedTimeSchema.t() | nil
  def get_for_type(meeting_type_id, id) do
    Repo.get_by(OfferedTimeSchema, id: id, meeting_type_id: meeting_type_id)
  end

  @spec count_for_type(integer()) :: non_neg_integer()
  def count_for_type(meeting_type_id) do
    OfferedTimeSchema
    |> where([t], t.meeting_type_id == ^meeting_type_id)
    |> Repo.aggregate(:count)
  end

  @spec insert(Ecto.Changeset.t()) :: {:ok, OfferedTimeSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert(changeset), do: Repo.insert(changeset)

  @spec delete(OfferedTimeSchema.t()) ::
          {:ok, OfferedTimeSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete(offered_time), do: Repo.delete(offered_time)

  @doc "Deletes every type's offered times starting before `cutoff`."
  @spec delete_before(DateTime.t()) :: {non_neg_integer(), nil}
  def delete_before(%DateTime{} = cutoff) do
    OfferedTimeSchema
    |> where([t], t.starts_at < ^cutoff)
    |> Repo.delete_all()
  end

  defp for_types_after(ids, since) do
    OfferedTimeSchema
    |> by_types(ids)
    |> starting_after(since)
    |> order_by([t], asc: t.starts_at, asc: t.id)
  end

  defp by_types(query, ids) when is_list(ids), do: where(query, [t], t.meeting_type_id in ^ids)
  defp by_types(query, id), do: where(query, [t], t.meeting_type_id == ^id)

  defp starting_after(query, nil), do: query
  defp starting_after(query, since), do: where(query, [t], t.starts_at > ^since)
end
