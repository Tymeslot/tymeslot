defmodule Tymeslot.CalendarGrid.CalendarSetQueries do
  @moduledoc "Database access for `calendar_sets`. No rules here; see `CalendarSets`."

  import Ecto.Query

  alias Tymeslot.CalendarGrid.CalendarSetSchema
  alias Tymeslot.Repo

  @spec list_for_user(integer()) :: [CalendarSetSchema.t()]
  def list_for_user(user_id) do
    CalendarSetSchema
    |> where([set], set.user_id == ^user_id)
    |> order_by([set], asc: set.position)
    |> Repo.all()
  end

  @spec get_for_user(integer(), integer()) :: CalendarSetSchema.t() | nil
  def get_for_user(user_id, position),
    do: Repo.get_by(CalendarSetSchema, user_id: user_id, position: position)

  @spec insert(map()) :: {:ok, CalendarSetSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert(attrs),
    do: %CalendarSetSchema{} |> CalendarSetSchema.changeset(attrs) |> Repo.insert()

  @spec update(CalendarSetSchema.t(), map()) ::
          {:ok, CalendarSetSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(set, attrs), do: set |> CalendarSetSchema.changeset(attrs) |> Repo.update()

  @spec update_members(CalendarSetSchema.t(), [map()]) ::
          {:ok, CalendarSetSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_members(set, members),
    do: set |> CalendarSetSchema.members_changeset(members) |> Repo.update()

  @spec delete(CalendarSetSchema.t()) ::
          {:ok, CalendarSetSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete(set), do: Repo.delete(set)
end
