defmodule Tymeslot.Venues.VenueQueries do
  @moduledoc """
  Every database call for `venues`. All reads are scoped to the owner.
  """
  import Ecto.Query, warn: false

  alias Tymeslot.Repo
  alias Tymeslot.Venues.VenueSchema

  @doc "The owner's venues, in the owner's order."
  @spec list_for_user(integer()) :: [VenueSchema.t()]
  def list_for_user(user_id) do
    Repo.all(
      from(v in VenueSchema,
        where: v.user_id == ^user_id,
        order_by: [asc: v.position, asc: v.id]
      )
    )
  end

  @doc "The position a new venue of the owner takes: after all the others."
  @spec next_position(integer()) :: non_neg_integer()
  # Concurrent creates may tie on position, which is harmless (ties break by
  # id), so there is no unique index on position.
  def next_position(user_id) do
    highest =
      Repo.one(from(v in VenueSchema, where: v.user_id == ^user_id, select: max(v.position)))

    case highest do
      nil -> 0
      highest -> highest + 1
    end
  end

  @doc """
  Renumbers the owner's venues in the order of `venue_ids`, in one
  transaction, the way `Tymeslot.MeetingTypes.MeetingTypeQueries.reorder_meeting_types/2`
  renumbers meeting types.

  Ids that are not the owner's are ignored. Owner's venues missing from
  `venue_ids` follow the listed ones in their current order, so the
  positions always stay one contiguous run.
  """
  @spec reorder(integer(), [integer()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def reorder(user_id, venue_ids) do
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      # Lock the owner's rows in one fixed order first, so two concurrent
      # reorders queue behind each other instead of deadlocking.
      Repo.all(
        from(v in VenueSchema,
          where: v.user_id == ^user_id,
          order_by: v.id,
          lock: "FOR UPDATE",
          select: v.id
        )
      )

      current = user_id |> list_for_user() |> Enum.map(& &1.id)
      listed = Enum.filter(venue_ids, &(&1 in current))
      ordered = listed ++ (current -- listed)

      ordered
      |> Enum.with_index()
      |> Enum.each(fn {venue_id, index} ->
        Repo.update_all(
          from(v in VenueSchema, where: v.id == ^venue_id and v.user_id == ^user_id),
          set: [position: index, updated_at: now]
        )
      end)

      length(ordered)
    end)
  end

  @doc "One of the owner's venues, or nil when it is missing or someone else's."
  @spec get_for_user(integer(), integer()) :: VenueSchema.t() | nil
  def get_for_user(user_id, id), do: Repo.get_by(VenueSchema, id: id, user_id: user_id)

  @doc "How many of `ids` are venues the owner holds."
  @spec count_owned(integer(), [integer()]) :: non_neg_integer()
  def count_owned(user_id, ids) do
    Repo.one(
      from(v in VenueSchema, where: v.user_id == ^user_id and v.id in ^ids, select: count(v.id))
    )
  end

  @doc "Inserts a venue changeset."
  @spec insert_venue(Ecto.Changeset.t()) :: {:ok, VenueSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert_venue(changeset), do: Repo.insert(changeset)

  @doc """
  Updates a venue changeset. A venue deleted since it was loaded comes back
  as a changeset with a stale error on `:id` rather than raising.
  """
  @spec update_venue(Ecto.Changeset.t()) :: {:ok, VenueSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_venue(changeset), do: Repo.update(changeset, stale_error_field: :id)

  @doc """
  Deletes a venue, matched by its id and owner. `{:error, :not_found}` when
  it is already gone, say deleted from another tab.
  """
  @spec delete_venue(VenueSchema.t()) :: {:ok, VenueSchema.t()} | {:error, :not_found}
  def delete_venue(%VenueSchema{id: id, user_id: user_id}) do
    query = from(v in VenueSchema, where: v.id == ^id and v.user_id == ^user_id, select: v)

    case Repo.delete_all(query) do
      {1, [deleted]} -> {:ok, deleted}
      {0, []} -> {:error, :not_found}
    end
  end
end
