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
  Gets the override that replaces a schedule's hours on a date. Extra times
  (`extra_hours`), of which a date may hold several, are not one.
  """
  @spec get_override_by_schedule_and_date(integer(), Date.t()) ::
          AvailabilityOverrideSchema.t() | nil
  def get_override_by_schedule_and_date(schedule_id, date) do
    AvailabilityOverrideSchema
    |> where([o], o.schedule_id == ^schedule_id and o.date == ^date)
    |> where([o], o.override_type != :extra_hours)
    |> Repo.one()
  end

  @doc "A schedule's extra times on `date`, earliest first."
  @spec list_extra_on(integer(), Date.t()) :: [AvailabilityOverrideSchema.t()]
  def list_extra_on(schedule_id, date) do
    extra(schedule_id)
    |> where([o], o.date == ^date)
    |> order_by(asc: :start_time)
    |> Repo.all()
  end

  @doc "A schedule's extra times from `from_date` on, in date and time order."
  @spec list_extra_from(integer(), Date.t()) :: [AvailabilityOverrideSchema.t()]
  def list_extra_from(schedule_id, from_date) do
    extra(schedule_id)
    |> where([o], o.date >= ^from_date)
    |> order_by(asc: :date, asc: :start_time)
    |> Repo.all()
  end

  @doc "One of a schedule's extra times."
  @spec get_extra(integer(), integer()) :: AvailabilityOverrideSchema.t() | nil
  def get_extra(schedule_id, id) do
    extra(schedule_id)
    |> where([o], o.id == ^id)
    |> Repo.one()
  end

  @spec count_extra(integer()) :: non_neg_integer()
  def count_extra(schedule_id) do
    schedule_id |> extra() |> Repo.aggregate(:count)
  end

  @spec insert(Ecto.Changeset.t()) ::
          {:ok, AvailabilityOverrideSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert(changeset), do: Repo.insert(changeset)

  @spec delete(AvailabilityOverrideSchema.t()) ::
          {:ok, AvailabilityOverrideSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete(override), do: Repo.delete(override)

  @doc "Deletes every schedule's extra times on dates before `date`."
  @spec delete_extra_before(Date.t()) :: {non_neg_integer(), nil}
  def delete_extra_before(%Date{} = date) do
    AvailabilityOverrideSchema
    |> where([o], o.override_type == :extra_hours and o.date < ^date)
    |> Repo.delete_all()
  end

  defp extra(schedule_id) do
    where(
      AvailabilityOverrideSchema,
      [o],
      o.schedule_id == ^schedule_id and o.override_type == :extra_hours
    )
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
    |> where([o], o.override_type != :extra_hours)
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
  Writes the schedule's override on `attrs.date` in one statement: inserts
  it, or, when the date already has one (even one another transaction has
  just inserted), replaces its type, hours and reason. Concurrent writes for
  one date therefore never fail on the unique index; the last to commit
  stands.

  Extra available times (`extra_hours`) are not written here: a date may
  hold several, so the unique index, and the conflict target with it, covers
  every other type only.
  """
  @spec upsert_override(map()) ::
          {:ok, AvailabilityOverrideSchema.t()} | {:error, Ecto.Changeset.t()}
  def upsert_override(attrs) when is_map(attrs) do
    %AvailabilityOverrideSchema{}
    |> AvailabilityOverrideSchema.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace, [:override_type, :start_time, :end_time, :ends_next_day, :reason, :updated_at]},
      conflict_target:
        {:unsafe_fragment, "(schedule_id, date) WHERE override_type <> 'extra_hours'"},
      returning: true
    )
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
  rows went (0 or 1). The date's extra times (`list_extra_on/2`) are not
  its override, and stay.
  """
  @spec delete_by_schedule_and_date(integer(), Date.t()) :: non_neg_integer()
  def delete_by_schedule_and_date(schedule_id, date) do
    {count, _rows} =
      AvailabilityOverrideSchema
      |> where([o], o.schedule_id == ^schedule_id and o.date == ^date)
      |> where([o], o.override_type != :extra_hours)
      |> Repo.delete_all()

    count
  end
end
