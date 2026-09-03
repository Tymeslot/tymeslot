defmodule Tymeslot.Availability.TimeOffPeriodQueries do
  @moduledoc """
  Query interface for time-off periods.

  Periods belong to a profile, so the profile-keyed lookups are the primary
  ones. `list_for_schedule_in_range/3` exists because the availability
  calculation only ever knows the schedule it is computing for, and joining
  from schedule to profile here keeps that single hop out of `BusinessHours`.
  """
  import Ecto.Query, warn: false

  alias Tymeslot.Availability.AvailabilityScheduleSchema
  alias Tymeslot.Availability.TimeOffPeriodSchema
  alias Tymeslot.Repo

  @doc """
  Lists a profile's periods, soonest-starting first.
  """
  @spec list_for_profile(integer()) :: [TimeOffPeriodSchema.t()]
  def list_for_profile(profile_id) do
    TimeOffPeriodSchema
    |> where([p], p.profile_id == ^profile_id)
    |> order_by(asc: :starts_on, asc: :id)
    |> Repo.all()
  end

  @doc """
  Lists a profile's periods that overlap `start_date..end_date` inclusive.
  """
  @spec list_for_profile_in_range(integer(), Date.t(), Date.t()) :: [TimeOffPeriodSchema.t()]
  def list_for_profile_in_range(profile_id, start_date, end_date) do
    TimeOffPeriodSchema
    |> where([p], p.profile_id == ^profile_id)
    |> overlapping(start_date, end_date)
    |> order_by(asc: :starts_on, asc: :id)
    |> Repo.all()
  end

  @doc """
  Lists the periods overlapping `start_date..end_date` for the profile that
  owns `schedule_id`.

  Returns `[]` for an unknown schedule, matching the rest of the availability
  read path: a schedule that cannot be resolved offers no time off rather than
  raising inside a booking-page render.
  """
  @spec list_for_schedule_in_range(integer(), Date.t(), Date.t()) :: [TimeOffPeriodSchema.t()]
  def list_for_schedule_in_range(schedule_id, start_date, end_date) do
    TimeOffPeriodSchema
    |> join(:inner, [p], s in AvailabilityScheduleSchema, on: s.profile_id == p.profile_id)
    |> where([_p, s], s.id == ^schedule_id)
    |> overlapping(start_date, end_date)
    |> order_by([p], asc: p.starts_on, asc: p.id)
    |> Repo.all()
  end

  @doc """
  Gets one of a profile's periods. Returns nil when the period does not exist
  or belongs to another profile.
  """
  @spec get_for_profile(integer(), integer()) :: TimeOffPeriodSchema.t() | nil
  def get_for_profile(profile_id, id) do
    Repo.get_by(TimeOffPeriodSchema, id: id, profile_id: profile_id)
  end

  @doc """
  How many periods a profile owns.
  """
  @spec count_for_profile(integer()) :: non_neg_integer()
  def count_for_profile(profile_id) do
    TimeOffPeriodSchema
    |> where([p], p.profile_id == ^profile_id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Creates a time-off period.
  """
  @spec create(map()) :: {:ok, TimeOffPeriodSchema.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs \\ %{}) when is_map(attrs) do
    %TimeOffPeriodSchema{}
    |> TimeOffPeriodSchema.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a time-off period.
  """
  @spec update(TimeOffPeriodSchema.t(), map()) ::
          {:ok, TimeOffPeriodSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(%TimeOffPeriodSchema{} = period, attrs) when is_map(attrs) do
    period
    |> TimeOffPeriodSchema.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a time-off period.
  """
  @spec delete(TimeOffPeriodSchema.t()) ::
          {:ok, TimeOffPeriodSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete(%TimeOffPeriodSchema{} = period), do: Repo.delete(period)

  # A period overlaps the window when it starts on or before the window ends
  # and ends on or after the window starts.
  defp overlapping(query, start_date, end_date) do
    where(query, [p], p.starts_on <= ^end_date and p.ends_on >= ^start_date)
  end
end
