defmodule Tymeslot.DatabaseQueries.AvailabilityBreakQueries do
  @moduledoc """
  Query interface for availability break-related database operations.
  """
  import Ecto.Query, warn: false
  alias Tymeslot.DatabaseSchemas.AvailabilityBreakSchema
  alias Tymeslot.Repo

  @doc """
  Gets a single availability break.
  Returns nil if the break does not exist.
  """
  @spec get_break(integer()) :: AvailabilityBreakSchema.t() | nil
  def get_break(id), do: Repo.get(AvailabilityBreakSchema, id)

  @doc """
  Tagged-tuple variant: returns {:ok, break} | {:error, :not_found}.
  """
  @spec get_break_t(integer()) :: {:ok, AvailabilityBreakSchema.t()} | {:error, :not_found}
  def get_break_t(id) do
    case get_break(id) do
      nil -> {:error, :not_found}
      b -> {:ok, b}
    end
  end

  @doc """
  Gets all breaks for a weekly availability.
  """
  @spec get_breaks_by_weekly_availability(integer()) :: [AvailabilityBreakSchema.t()]
  def get_breaks_by_weekly_availability(weekly_availability_id) do
    AvailabilityBreakSchema
    |> where([b], b.weekly_availability_id == ^weekly_availability_id)
    |> order_by(asc: :sort_order)
    |> Repo.all()
  end

  @doc """
  Creates an availability break.
  """
  @spec create_break(map()) :: {:ok, AvailabilityBreakSchema.t()} | {:error, Ecto.Changeset.t()}
  def create_break(attrs \\ %{}) when is_map(attrs) do
    %AvailabilityBreakSchema{}
    |> AvailabilityBreakSchema.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an availability break.
  """
  @spec update_break(AvailabilityBreakSchema.t(), map()) ::
          {:ok, AvailabilityBreakSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_break(%AvailabilityBreakSchema{} = break, attrs) when is_map(attrs) do
    break
    |> AvailabilityBreakSchema.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an availability break.
  """
  @spec delete_break(AvailabilityBreakSchema.t()) ::
          {:ok, AvailabilityBreakSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_break(%AvailabilityBreakSchema{} = break) do
    Repo.delete(break)
  end

  @doc """
  Deletes all breaks for a weekly availability.
  """
  @spec delete_breaks_by_weekly_availability(integer()) :: {non_neg_integer(), nil | [term()]}
  def delete_breaks_by_weekly_availability(weekly_availability_id) do
    Repo.delete_all(
      where(AvailabilityBreakSchema, [b], b.weekly_availability_id == ^weekly_availability_id)
    )
  end

  @doc """
  Gets breaks within a time range for a weekly availability.
  """
  @spec get_breaks_in_time_range(integer(), Time.t(), Time.t()) ::
          list(AvailabilityBreakSchema.t())
  def get_breaks_in_time_range(weekly_availability_id, start_time, end_time) do
    AvailabilityBreakSchema
    |> where([b], b.weekly_availability_id == ^weekly_availability_id)
    |> where([b], b.start_time < ^end_time and b.end_time > ^start_time)
    |> order_by(asc: :start_time)
    |> Repo.all()
  end

  @doc """
  Gets the next sort order for a weekly availability.
  """
  @spec get_next_sort_order(integer()) :: non_neg_integer()
  def get_next_sort_order(weekly_availability_id) do
    result =
      AvailabilityBreakSchema
      |> where([b], b.weekly_availability_id == ^weekly_availability_id)
      |> select([b], max(b.sort_order))
      |> Repo.one()

    case result do
      nil -> 0
      max_order -> max_order + 1
    end
  end

  @doc """
  Gets work hours for a weekly availability.
  """
  @spec get_work_hours(integer()) :: {Time.t() | nil, Time.t() | nil} | nil
  def get_work_hours(weekly_availability_id) do
    query =
      from(wa in "weekly_availability",
        where: wa.id == ^weekly_availability_id,
        select: {wa.start_time, wa.end_time}
      )

    Repo.one(query)
  end

  @doc """
  Gets existing breaks for validation, excluding a specific break.
  """
  @spec get_existing_breaks_for_validation(integer(), integer() | nil) ::
          list({integer(), Time.t(), Time.t()})
  def get_existing_breaks_for_validation(weekly_availability_id, exclude_break_id \\ nil) do
    query =
      from(b in AvailabilityBreakSchema,
        where: b.weekly_availability_id == ^weekly_availability_id,
        select: {b.id, b.start_time, b.end_time}
      )

    query =
      if exclude_break_id do
        where(query, [b], b.id != ^exclude_break_id)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Updates all breaks for a weekly availability with new sort orders.
  """
  @spec reorder_breaks(integer(), [integer()]) :: {:ok, any()} | {:error, any()}
  def reorder_breaks(weekly_availability_id, break_ids) when is_list(break_ids) do
    Repo.transaction(fn ->
      Enum.with_index(break_ids, fn break_id, index ->
        AvailabilityBreakSchema
        |> where([b], b.id == ^break_id and b.weekly_availability_id == ^weekly_availability_id)
        |> Repo.update_all(set: [sort_order: index])
      end)
    end)
  end

  @doc """
  Inserts a changeset directly.
  Used when validation has been performed in the calling module.
  """
  @spec insert_changeset(Ecto.Changeset.t()) ::
          {:ok, AvailabilityBreakSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert_changeset(changeset) do
    Repo.insert(changeset)
  end

  @doc """
  Updates a changeset directly.
  Used when validation has been performed in the calling module.
  """
  @spec update_changeset(Ecto.Changeset.t()) ::
          {:ok, AvailabilityBreakSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_changeset(changeset) do
    Repo.update(changeset)
  end
end
