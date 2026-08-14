defmodule Tymeslot.Availability.AvailabilityOverrideQueries do
  @moduledoc """
  Query interface for availability override-related database operations.

  Overrides hang off an availability schedule, so every lookup here is keyed by
  `schedule_id` rather than by profile.
  """
  import Ecto.Query, warn: false
  alias Tymeslot.Availability.AvailabilityOverrideSchema
  alias Tymeslot.Repo

  @doc """
  Gets a single availability override.
  Returns nil if the override does not exist.
  """
  @spec get_override(integer()) :: AvailabilityOverrideSchema.t() | nil
  def get_override(id), do: Repo.get(AvailabilityOverrideSchema, id)

  @doc """
  Tagged-tuple variant: returns {:ok, override} | {:error, :not_found}.
  """
  @spec get_override_t(integer()) :: {:ok, AvailabilityOverrideSchema.t()} | {:error, :not_found}
  def get_override_t(id) do
    case get_override(id) do
      nil -> {:error, :not_found}
      o -> {:ok, o}
    end
  end

  @doc """
  Gets an override by schedule and date.
  """
  @spec get_override_by_schedule_and_date(integer(), Date.t()) ::
          AvailabilityOverrideSchema.t() | nil
  def get_override_by_schedule_and_date(schedule_id, date) do
    Repo.get_by(AvailabilityOverrideSchema, schedule_id: schedule_id, date: date)
  end

  @doc """
  Gets overrides for a schedule within a date range.
  """
  @spec get_overrides_by_schedule_and_date_range(integer(), Date.t(), Date.t()) ::
          list(AvailabilityOverrideSchema.t())
  def get_overrides_by_schedule_and_date_range(schedule_id, start_date, end_date) do
    AvailabilityOverrideSchema
    |> where([o], o.schedule_id == ^schedule_id)
    |> where([o], o.date >= ^start_date and o.date <= ^end_date)
    |> order_by(asc: :date)
    |> Repo.all()
  end

  @doc """
  How many date overrides a schedule owns.
  """
  @spec count_by_schedule(integer()) :: non_neg_integer()
  def count_by_schedule(schedule_id) do
    AvailabilityOverrideSchema
    |> where([o], o.schedule_id == ^schedule_id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Creates an availability override.
  """
  @spec create_override(map()) ::
          {:ok, AvailabilityOverrideSchema.t()} | {:error, Ecto.Changeset.t()}
  def create_override(attrs \\ %{}) when is_map(attrs) do
    %AvailabilityOverrideSchema{}
    |> AvailabilityOverrideSchema.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an availability override.
  """
  @spec update_override(AvailabilityOverrideSchema.t(), map()) ::
          {:ok, AvailabilityOverrideSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_override(%AvailabilityOverrideSchema{} = override, attrs) when is_map(attrs) do
    override
    |> AvailabilityOverrideSchema.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an availability override.
  """
  @spec delete_override(AvailabilityOverrideSchema.t()) ::
          {:ok, AvailabilityOverrideSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_override(%AvailabilityOverrideSchema{} = override) do
    Repo.delete(override)
  end
end
