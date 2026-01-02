defmodule Tymeslot.DatabaseQueries.WeeklyAvailabilityQueries do
  @moduledoc """
  Query interface for weekly availability-related database operations.
  """
  import Ecto.Query, warn: false
  alias Tymeslot.DatabaseSchemas.{AvailabilityBreakSchema, WeeklyAvailabilitySchema}
  alias Tymeslot.Repo

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
  Gets weekly availability by profile and day of week.
  """
  @spec get_weekly_availability_by_profile_and_day(integer(), integer()) ::
          WeeklyAvailabilitySchema.t() | nil
  def get_weekly_availability_by_profile_and_day(profile_id, day_of_week) do
    Repo.get_by(WeeklyAvailabilitySchema, profile_id: profile_id, day_of_week: day_of_week)
  end

  @doc """
  Tagged-tuple variant: returns {:ok, weekly_availability} | {:error, :not_found}.
  """
  @spec get_weekly_availability_by_profile_and_day_t(integer(), integer()) ::
          {:ok, WeeklyAvailabilitySchema.t()} | {:error, :not_found}
  def get_weekly_availability_by_profile_and_day_t(profile_id, day_of_week) do
    case get_weekly_availability_by_profile_and_day(profile_id, day_of_week) do
      nil -> {:error, :not_found}
      wa -> {:ok, wa}
    end
  end

  @doc """
  Gets all weekly availability for a profile.
  """
  @spec get_weekly_availability_by_profile(integer()) :: [WeeklyAvailabilitySchema.t()]
  def get_weekly_availability_by_profile(profile_id) do
    WeeklyAvailabilitySchema
    |> where([w], w.profile_id == ^profile_id)
    |> order_by(asc: :day_of_week)
    |> Repo.all()
  end

  @doc """
  Gets all weekly availability for a profile with breaks preloaded.
  """
  @spec get_weekly_availability_with_breaks(integer()) :: [WeeklyAvailabilitySchema.t()]
  def get_weekly_availability_with_breaks(profile_id) do
    WeeklyAvailabilitySchema
    |> where([w], w.profile_id == ^profile_id)
    |> preload(:breaks)
    |> order_by(asc: :day_of_week)
    |> Repo.all()
  end

  @doc """
  Gets available days for a profile (where is_available is true).
  """
  @spec get_available_days_by_profile(integer()) :: [WeeklyAvailabilitySchema.t()]
  def get_available_days_by_profile(profile_id) do
    WeeklyAvailabilitySchema
    |> where([w], w.profile_id == ^profile_id and w.is_available == true)
    |> order_by(asc: :day_of_week)
    |> Repo.all()
  end

  @doc """
  Gets available days for a profile with breaks preloaded.
  """
  @spec get_available_days_with_breaks(integer()) :: [WeeklyAvailabilitySchema.t()]
  def get_available_days_with_breaks(profile_id) do
    WeeklyAvailabilitySchema
    |> where([w], w.profile_id == ^profile_id and w.is_available == true)
    |> preload(:breaks)
    |> order_by(asc: :day_of_week)
    |> Repo.all()
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
  Deletes all weekly availability for a profile.
  """
  @spec delete_weekly_availability_by_profile(integer()) :: {non_neg_integer(), nil | [term()]}
  def delete_weekly_availability_by_profile(profile_id) do
    Repo.delete_all(where(WeeklyAvailabilitySchema, [w], w.profile_id == ^profile_id))
  end

  @doc """
  Upserts weekly availability (insert or update if exists).
  """
  @spec upsert_weekly_availability(map()) ::
          {:ok, WeeklyAvailabilitySchema.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}
          | {atom(), term()}
  def upsert_weekly_availability(attrs) when is_map(attrs) do
    %WeeklyAvailabilitySchema{}
    |> WeeklyAvailabilitySchema.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:is_available, :start_time, :end_time, :updated_at]},
      conflict_target: [:profile_id, :day_of_week]
    )
  end

  @doc """
  Gets the complete weekly schedule for a profile including breaks.
  """
  @spec get_weekly_schedule_with_breaks(integer()) :: [WeeklyAvailabilitySchema.t()]
  def get_weekly_schedule_with_breaks(profile_id) do
    breaks_query = from(b in AvailabilityBreakSchema, order_by: b.sort_order)

    WeeklyAvailabilitySchema
    |> where([wa], wa.profile_id == ^profile_id)
    |> preload([wa], breaks: ^breaks_query)
    |> order_by([wa], wa.day_of_week)
    |> Repo.all()
  end

  @doc """
  Gets availability for a specific day of the week with breaks.
  """
  @spec get_day_availability_with_breaks(integer(), integer()) ::
          WeeklyAvailabilitySchema.t() | nil
  def get_day_availability_with_breaks(profile_id, day_of_week) do
    breaks_query = from(b in AvailabilityBreakSchema, order_by: b.sort_order)

    WeeklyAvailabilitySchema
    |> where([wa], wa.profile_id == ^profile_id and wa.day_of_week == ^day_of_week)
    |> preload([wa], breaks: ^breaks_query)
    |> Repo.one()
  end

  @doc """
  Tagged-tuple variant: returns {:ok, weekly_availability} | {:error, :not_found}.
  """
  @spec get_day_availability_with_breaks_t(integer(), integer()) ::
          {:ok, WeeklyAvailabilitySchema.t()} | {:error, :not_found}
  def get_day_availability_with_breaks_t(profile_id, day_of_week) do
    case get_day_availability_with_breaks(profile_id, day_of_week) do
      nil -> {:error, :not_found}
      wa -> {:ok, wa}
    end
  end

  @doc """
  Creates default weekly schedule for a new profile.
  """
  @spec create_default_weekly_schedule(integer()) ::
          {:ok, non_neg_integer()} | {:error, :failed_to_create_schedule}
  def create_default_weekly_schedule(profile_id) do
    now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

    # Build all entries at once
    # Monday to Friday (1-5)
    # Saturday and Sunday (6-7)
    entries =
      Enum.map(1..5, fn day ->
        %{
          profile_id: profile_id,
          day_of_week: day,
          is_available: true,
          start_time: ~T[11:00:00],
          end_time: ~T[19:30:00],
          inserted_at: now,
          updated_at: now
        }
      end) ++
        Enum.map(6..7, fn day ->
          %{
            profile_id: profile_id,
            day_of_week: day,
            is_available: false,
            start_time: nil,
            end_time: nil,
            inserted_at: now,
            updated_at: now
          }
        end)

    # Bulk insert all 7 days at once
    case Repo.insert_all(WeeklyAvailabilitySchema, entries) do
      {count, _} when count == 7 -> {:ok, count}
      {_count, _} -> {:error, :failed_to_create_schedule}
    end
  end

  @doc """
  Performs a database transaction.
  """
  @spec transaction((-> any())) :: {:ok, any()} | {:error, any()}
  def transaction(fun) do
    Repo.transaction(fun)
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

    # Create new breaks
    Enum.each(breaks, fn break ->
      %AvailabilityBreakSchema{}
      |> AvailabilityBreakSchema.changeset(%{
        weekly_availability_id: target_weekly_availability_id,
        start_time: break.start_time,
        end_time: break.end_time,
        label: break.label,
        sort_order: break.sort_order
      })
      |> Repo.insert!()
    end)
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

  @doc """
  Rolls back a transaction.
  """
  @spec rollback(term()) :: no_return()
  def rollback(reason) do
    Repo.rollback(reason)
  end
end
