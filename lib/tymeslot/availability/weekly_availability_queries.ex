defmodule Tymeslot.Availability.WeeklyAvailabilityQueries do
  @moduledoc """
  Query interface for weekly availability-related database operations.

  Weekly rows hang off an availability schedule, so every lookup here is keyed
  by `schedule_id` rather than by profile.
  """
  import Ecto.Query, warn: false
  alias Tymeslot.Availability.{AvailabilityBreakSchema, WeeklyAvailabilitySchema}
  alias Tymeslot.Clock
  alias Tymeslot.Repo

  @default_start_time ~T[11:00:00]
  @default_end_time ~T[19:30:00]

  @doc """
  The start time given to weekdays in a freshly created schedule.
  """
  @spec default_start_time() :: Time.t()
  def default_start_time, do: @default_start_time

  @doc """
  The end time given to weekdays in a freshly created schedule.
  """
  @spec default_end_time() :: Time.t()
  def default_end_time, do: @default_end_time

  @doc """
  Gets a single weekly availability.
  Returns nil if the weekly availability does not exist.
  """
  @spec get_weekly_availability(integer()) :: WeeklyAvailabilitySchema.t() | nil
  def get_weekly_availability(id), do: Repo.get(WeeklyAvailabilitySchema, id)

  @doc """
  Tagged-tuple variant: returns {:ok, weekly_availability} | {:error, :not_found}.
  """
  @spec get_weekly_availability_t(integer()) ::
          {:ok, WeeklyAvailabilitySchema.t()} | {:error, :not_found}
  def get_weekly_availability_t(id) do
    case get_weekly_availability(id) do
      nil -> {:error, :not_found}
      wa -> {:ok, wa}
    end
  end

  @doc """
  Gets weekly availability by schedule and day of week.
  """
  @spec get_weekly_availability_by_schedule_and_day(integer(), integer()) ::
          WeeklyAvailabilitySchema.t() | nil
  def get_weekly_availability_by_schedule_and_day(schedule_id, day_of_week) do
    Repo.get_by(WeeklyAvailabilitySchema, schedule_id: schedule_id, day_of_week: day_of_week)
  end

  @doc """
  Tagged-tuple variant: returns {:ok, weekly_availability} | {:error, :not_found}.
  """
  @spec get_weekly_availability_by_schedule_and_day_t(integer(), integer()) ::
          {:ok, WeeklyAvailabilitySchema.t()} | {:error, :not_found}
  def get_weekly_availability_by_schedule_and_day_t(schedule_id, day_of_week) do
    case get_weekly_availability_by_schedule_and_day(schedule_id, day_of_week) do
      nil -> {:error, :not_found}
      wa -> {:ok, wa}
    end
  end

  @doc """
  Creates a weekly availability.
  """
  @spec create_weekly_availability(map()) ::
          {:ok, WeeklyAvailabilitySchema.t()} | {:error, Ecto.Changeset.t()}
  def create_weekly_availability(attrs \\ %{}) when is_map(attrs) do
    %WeeklyAvailabilitySchema{}
    |> WeeklyAvailabilitySchema.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a weekly availability.
  """
  @spec update_weekly_availability(WeeklyAvailabilitySchema.t(), map()) ::
          {:ok, WeeklyAvailabilitySchema.t()} | {:error, Ecto.Changeset.t()}
  def update_weekly_availability(%WeeklyAvailabilitySchema{} = weekly_availability, attrs)
      when is_map(attrs) do
    weekly_availability
    |> WeeklyAvailabilitySchema.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a weekly availability.
  """
  @spec delete_weekly_availability(WeeklyAvailabilitySchema.t()) ::
          {:ok, WeeklyAvailabilitySchema.t()} | {:error, Ecto.Changeset.t()}
  def delete_weekly_availability(%WeeklyAvailabilitySchema{} = weekly_availability) do
    Repo.delete(weekly_availability)
  end

  @doc """
  Gets the complete weekly schedule for a schedule including breaks.
  """
  @spec get_weekly_schedule_with_breaks(integer()) :: [WeeklyAvailabilitySchema.t()]
  def get_weekly_schedule_with_breaks(schedule_id) do
    breaks_query = from(b in AvailabilityBreakSchema, order_by: b.sort_order)

    WeeklyAvailabilitySchema
    |> where([wa], wa.schedule_id == ^schedule_id)
    |> preload([wa], breaks: ^breaks_query)
    |> order_by([wa], wa.day_of_week)
    |> Repo.all()
  end

  @doc """
  Gets availability for a specific day of the week with breaks.
  """
  @spec get_day_availability_with_breaks(integer(), integer()) ::
          WeeklyAvailabilitySchema.t() | nil
  def get_day_availability_with_breaks(schedule_id, day_of_week) do
    breaks_query = from(b in AvailabilityBreakSchema, order_by: b.sort_order)

    WeeklyAvailabilitySchema
    |> where([wa], wa.schedule_id == ^schedule_id and wa.day_of_week == ^day_of_week)
    |> preload([wa], breaks: ^breaks_query)
    |> Repo.one()
  end

  @doc """
  Creates the seven default weekly days for a new schedule.

  Accepts an optional `repo` argument so callers inside an existing database
  transaction can pass their transaction-scoped repo, ensuring the inserts are
  part of the same transaction rather than a separate connection.
  """
  @spec create_default_weekly_days(integer(), Ecto.Repo.t()) ::
          {:ok, non_neg_integer()} | {:error, :failed_to_create_schedule}
  def create_default_weekly_days(schedule_id, repo \\ Repo) do
    now = DateTime.truncate(Clock.utc_now(), :second)

    # Build all entries at once
    # Monday to Friday (1-5)
    # Saturday and Sunday (6-7)
    entries =
      Enum.map(1..5, fn day ->
        %{
          schedule_id: schedule_id,
          day_of_week: day,
          is_available: true,
          start_time: @default_start_time,
          end_time: @default_end_time,
          inserted_at: now,
          updated_at: now
        }
      end) ++
        Enum.map(6..7, fn day ->
          %{
            schedule_id: schedule_id,
            day_of_week: day,
            is_available: false,
            start_time: nil,
            end_time: nil,
            inserted_at: now,
            updated_at: now
          }
        end)

    # Bulk insert all 7 days at once. on_conflict: :nothing ensures that a
    # pre-existing row for the same (schedule_id, day_of_week) silently skips
    # rather than raising; the count check below then surfaces the mismatch.
    case repo.insert_all(WeeklyAvailabilitySchema, entries,
           on_conflict: :nothing,
           conflict_target: [:schedule_id, :day_of_week]
         ) do
      {count, _value} when count == 7 -> {:ok, count}
      {_count, _value} -> {:error, :failed_to_create_schedule}
    end
  end

  @doc """
  Deletes all breaks for a weekly availability and creates new ones.
  """
  @type break_input :: %{
          required(:start_time) => Time.t(),
          required(:end_time) => Time.t(),
          required(:label) => String.t() | nil,
          required(:sort_order) => integer()
        }
  @spec replace_breaks(integer(), [break_input()]) :: :ok
  def replace_breaks(target_weekly_availability_id, breaks) do
    # Delete existing breaks for the target day
    Repo.delete_all(
      where(
        AvailabilityBreakSchema,
        [b],
        b.weekly_availability_id == ^target_weekly_availability_id
      )
    )

    # Bulk insert new breaks
    unless Enum.empty?(breaks) do
      now = DateTime.truncate(Clock.utc_now(), :second)

      entries =
        Enum.map(breaks, fn break ->
          %{
            weekly_availability_id: target_weekly_availability_id,
            start_time: break.start_time,
            end_time: break.end_time,
            label: break.label,
            sort_order: break.sort_order,
            inserted_at: now,
            updated_at: now
          }
        end)

      Repo.insert_all(AvailabilityBreakSchema, entries)
    end

    :ok
  end

  @doc """
  Clears all breaks for a specific day's availability.
  """
  @spec clear_breaks_for_day(integer()) :: {non_neg_integer(), nil | [term()]}
  def clear_breaks_for_day(weekly_availability_id) do
    Repo.delete_all(
      where(AvailabilityBreakSchema, [b], b.weekly_availability_id == ^weekly_availability_id)
    )
  end
end
