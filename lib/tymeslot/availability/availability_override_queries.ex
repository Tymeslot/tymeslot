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
end
