defmodule Tymeslot.Availability.WeeklySchedule do
  @moduledoc """
  Context for managing weekly availability schedules.
  """

  alias Tymeslot.DatabaseQueries.WeeklyAvailabilityQueries
  alias Tymeslot.DatabaseSchemas.WeeklyAvailabilitySchema

  @doc """
  Gets the complete weekly schedule for a profile including breaks.
  """
  @spec get_weekly_schedule(integer()) :: list(WeeklyAvailabilitySchema.t())
  def get_weekly_schedule(profile_id) do
    WeeklyAvailabilityQueries.get_weekly_schedule_with_breaks(profile_id)
  end

  @doc """
  Gets availability for a specific day of the week.
  """
  @spec get_day_availability(integer(), integer()) :: WeeklyAvailabilitySchema.t() | nil
  def get_day_availability(profile_id, day_of_week) do
    WeeklyAvailabilityQueries.get_day_availability_with_breaks(profile_id, day_of_week)
  end

  @doc """
  Creates or updates availability for a specific day.
  """
  @spec upsert_day_availability(integer(), integer(), map()) ::
          {:ok, WeeklyAvailabilitySchema.t()} | {:error, Ecto.Changeset.t() | String.t()}
  def upsert_day_availability(profile_id, day_of_week, attrs) do
    case get_day_availability(profile_id, day_of_week) do
      nil ->
        create_day_availability(profile_id, day_of_week, attrs)

      existing ->
        update_day_availability(existing, attrs)
    end
  end

  @doc """
  Creates availability for a specific day.
  """
  @spec create_day_availability(integer(), integer(), map()) ::
          {:ok, WeeklyAvailabilitySchema.t()} | {:error, Ecto.Changeset.t()}
  def create_day_availability(profile_id, day_of_week, attrs) do
    attrs = Map.merge(attrs, %{profile_id: profile_id, day_of_week: day_of_week})
    WeeklyAvailabilityQueries.create_weekly_availability(attrs)
  end

  @doc """
  Updates availability for a specific day.
  """
  @spec update_day_availability(WeeklyAvailabilitySchema.t(), map()) ::
          {:ok, WeeklyAvailabilitySchema.t()} | {:error, Ecto.Changeset.t()}
  def update_day_availability(%WeeklyAvailabilitySchema{} = weekly_availability, attrs) do
    WeeklyAvailabilityQueries.update_weekly_availability(weekly_availability, attrs)
  end

  @doc """
  Copies settings from one day to multiple other days.
  """
  @spec copy_day_settings(integer(), integer(), list(integer())) ::
          {:ok, term()} | {:error, String.t()}
  def copy_day_settings(profile_id, from_day, to_days) when is_list(to_days) do
    case get_day_availability(profile_id, from_day) do
      nil ->
        {:error, "Source day not found"}

      source ->
        WeeklyAvailabilityQueries.transaction(fn ->
          to_days
          |> Enum.reject(&(&1 == from_day))
          |> Enum.each(&copy_single_day_settings(source, profile_id, &1))
        end)
    end
  end

  @doc """
  Sets a preset schedule for specified days.
  """
  @spec set_preset_schedule(integer(), String.t(), list(integer())) ::
          {:ok, term()} | {:error, String.t()}
  def set_preset_schedule(profile_id, preset_name, days) when is_list(days) do
    case get_preset_config(preset_name) do
      nil -> {:error, "Unknown preset: #{preset_name}"}
      config -> apply_preset_in_tx(profile_id, days, config)
    end
  end

  defp apply_preset_in_tx(profile_id, days, config) do
    WeeklyAvailabilityQueries.transaction(fn ->
      Enum.each(days, &upsert_day_availability(profile_id, &1, config))
    end)
  end

  @doc """
  Creates default weekly schedule for a new profile.
  Weekdays 11AM-7:30PM, weekends unavailable.
  """
  @spec create_default_weekly_schedule(integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def create_default_weekly_schedule(profile_id) do
    WeeklyAvailabilityQueries.create_default_weekly_schedule(profile_id)
  end

  # Private functions

  defp copy_single_day_settings(source, profile_id, to_day) do
    # Create or update the target day
    attrs = %{
      is_available: source.is_available,
      start_time: source.start_time,
      end_time: source.end_time
    }

    case upsert_day_availability(profile_id, to_day, attrs) do
      {:ok, target_availability} ->
        # Copy breaks
        copy_breaks(source.breaks, target_availability.id)

      {:error, _changeset} = error ->
        WeeklyAvailabilityQueries.rollback(error)
    end
  end

  defp copy_breaks(breaks, target_weekly_availability_id) do
    WeeklyAvailabilityQueries.replace_breaks(target_weekly_availability_id, breaks)
  end

  defp get_preset_config("9-5") do
    %{
      is_available: true,
      start_time: ~T[09:00:00],
      end_time: ~T[17:00:00]
    }
  end

  defp get_preset_config("8-6") do
    %{
      is_available: true,
      start_time: ~T[08:00:00],
      end_time: ~T[18:00:00]
    }
  end

  defp get_preset_config("10-6") do
    %{
      is_available: true,
      start_time: ~T[10:00:00],
      end_time: ~T[18:00:00]
    }
  end

  defp get_preset_config("unavailable") do
    %{
      is_available: false
    }
  end

  defp get_preset_config(_), do: nil

  @doc """
  Clears all settings for a specific day (sets to unavailable and removes all breaks).
  """
  @spec clear_day_settings(integer(), integer()) ::
          {:ok, WeeklyAvailabilitySchema.t()} | {:error, Ecto.Changeset.t()}
  def clear_day_settings(profile_id, day_of_week) do
    case get_day_availability(profile_id, day_of_week) do
      nil ->
        # Day doesn't exist, create an unavailable day
        create_day_availability(profile_id, day_of_week, %{is_available: false})

      existing ->
        # Update to unavailable and clear times
        attrs = %{
          is_available: false,
          start_time: nil,
          end_time: nil
        }

        with {:ok, updated_availability} <- update_day_availability(existing, attrs) do
          # Clear all breaks for this day
          WeeklyAvailabilityQueries.clear_breaks_for_day(updated_availability.id)
          {:ok, updated_availability}
        end
    end
  end

  @doc """
  Gets available preset options.
  """
  @spec get_preset_options() :: list({String.t(), String.t()})
  def get_preset_options do
    [
      {"9 AM - 5 PM", "9-5"},
      {"8 AM - 6 PM", "8-6"},
      {"10 AM - 6 PM", "10-6"},
      {"Unavailable", "unavailable"}
    ]
  end
end
