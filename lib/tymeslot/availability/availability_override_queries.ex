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
  Gets an override by schedule and date.
  """
  @spec get_override_by_schedule_and_date(integer(), Date.t()) ::
          AvailabilityOverrideSchema.t() | nil
  def get_override_by_schedule_and_date(schedule_id, date) do
    Repo.get_by(AvailabilityOverrideSchema, schedule_id: schedule_id, date: date)
  end

  @doc """
  As `get_override_by_schedule_and_date/2`, locking the row (`FOR UPDATE`)
  until the caller's transaction ends.
  """
  @spec lock_override_by_schedule_and_date(integer(), Date.t()) ::
          AvailabilityOverrideSchema.t() | nil
  def lock_override_by_schedule_and_date(schedule_id, date) do
    AvailabilityOverrideSchema
    |> where([o], o.schedule_id == ^schedule_id and o.date == ^date)
    |> lock("FOR UPDATE")
    |> Repo.one()
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
  Deletes a schedule's override on `date`, if it has one. Returns how many
  rows went (0 or 1).
  """
  @spec delete_by_schedule_and_date(integer(), Date.t()) :: non_neg_integer()
  def delete_by_schedule_and_date(schedule_id, date) do
    {count, _rows} =
      AvailabilityOverrideSchema
      |> where([o], o.schedule_id == ^schedule_id and o.date == ^date)
      |> Repo.delete_all()

    count
  end
end
