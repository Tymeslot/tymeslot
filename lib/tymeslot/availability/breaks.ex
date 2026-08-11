defmodule Tymeslot.Availability.Breaks do
  @moduledoc """
  Context for managing availability breaks.
  """

  require Logger

  alias Ecto.Changeset
  alias Tymeslot.Availability.AvailabilityBreakQueries
  alias Tymeslot.Availability.AvailabilityBreakSchema
  alias Tymeslot.Availability.WeeklyAvailabilityQueries
  alias Tymeslot.Utils.TimeRange

  @doc """
  Gets all breaks for a weekly availability day.
  """
  @spec get_breaks_for_day(integer()) :: list(AvailabilityBreakSchema.t())
  def get_breaks_for_day(weekly_availability_id) do
    AvailabilityBreakQueries.get_breaks_by_weekly_availability(weekly_availability_id)
  end

  @doc """
  Adds a new break to a day.
  """
  @spec add_break(integer(), Time.t(), Time.t(), String.t() | nil) ::
          {:ok, AvailabilityBreakSchema.t()} | {:error, Ecto.Changeset.t()}
  def add_break(weekly_availability_id, start_time, end_time, label \\ nil) do
    # Get the next sort order
    next_sort_order = AvailabilityBreakQueries.get_next_sort_order(weekly_availability_id)

    attrs = %{
      weekly_availability_id: weekly_availability_id,
      start_time: start_time,
      end_time: end_time,
      label: label,
      sort_order: next_sort_order
    }

    %AvailabilityBreakSchema{}
    |> AvailabilityBreakSchema.changeset(attrs)
    |> validate_break_within_work_hours(weekly_availability_id)
    |> validate_no_break_overlap(weekly_availability_id)
    |> AvailabilityBreakQueries.insert_changeset()
  end

  @doc """
  Updates an existing break.
  """
  @spec update_break(integer(), map()) ::
          {:ok, AvailabilityBreakSchema.t()} | {:error, Ecto.Changeset.t() | String.t()}
  def update_break(break_id, attrs) when is_integer(break_id) and is_map(attrs) do
    case AvailabilityBreakQueries.get_break(break_id) do
      nil ->
        {:error, "Break not found"}

      break ->
        break
        |> AvailabilityBreakSchema.changeset(attrs)
        |> validate_break_within_work_hours(break.weekly_availability_id)
        |> validate_no_break_overlap(break.weekly_availability_id, break_id)
        |> AvailabilityBreakQueries.update_changeset()
    end
  end

  @doc """
  Deletes a break, verifying ownership against the given schedule_id.

  Returns `{:error, "Unauthorized"}` if the break belongs to a different schedule,
  or `{:error, "Break not found"}` if the break does not exist.
  """
  @spec delete_break(integer(), integer()) ::
          {:ok, AvailabilityBreakSchema.t()} | {:error, String.t()}
  def delete_break(break_id, schedule_id) do
    case AvailabilityBreakQueries.get_break(break_id) do
      nil ->
        {:error, "Break not found"}

      %AvailabilityBreakSchema{} = break ->
        case WeeklyAvailabilityQueries.get_weekly_availability(break.weekly_availability_id) do
          nil -> {:error, "Schedule not found"}
          %{schedule_id: ^schedule_id} -> AvailabilityBreakQueries.delete_break(break)
          %{schedule_id: _other} -> {:error, "Unauthorized"}
        end
    end
  end

  @doc """
  Reorders breaks based on a list of break IDs.
  """
  @spec reorder_breaks(integer(), list(integer())) :: {:ok, integer()} | {:error, term()}
  def reorder_breaks(weekly_availability_id, break_ids) when is_list(break_ids) do
    AvailabilityBreakQueries.reorder_breaks(weekly_availability_id, break_ids)
  end

  @doc """
  Adds a quick break with predefined duration.
  """
  @spec add_quick_break(integer(), Time.t(), integer(), String.t() | nil) ::
          {:ok, AvailabilityBreakSchema.t()} | {:error, Ecto.Changeset.t() | String.t()}
  def add_quick_break(weekly_availability_id, start_time, duration_minutes, label \\ nil)
      when is_integer(duration_minutes) and duration_minutes > 0 do
    end_time = Time.add(start_time, duration_minutes * 60, :second)

    if Time.compare(end_time, start_time) != :gt do
      {:error, "Break duration extends past end of day"}
    else
      add_break(weekly_availability_id, start_time, end_time, label)
    end
  rescue
    exception ->
      Logger.warning("Quick break time calculation failed",
        weekly_availability_id: weekly_availability_id,
        duration_minutes: duration_minutes,
        error: Exception.message(exception)
      )

      {:error, "Invalid time calculation"}
  end

  # Private functions

  defp validate_break_within_work_hours(changeset, weekly_availability_id) do
    with {work_start, work_end} <-
           AvailabilityBreakQueries.get_work_hours(weekly_availability_id),
         %Time{} = start_time <- Changeset.get_field(changeset, :start_time),
         %Time{} = end_time <- Changeset.get_field(changeset, :end_time) do
      cond do
        Time.compare(start_time, work_start) == :lt ->
          Changeset.add_error(changeset, :start_time, "cannot be before work hours")

        Time.compare(end_time, work_end) == :gt ->
          Changeset.add_error(changeset, :end_time, "cannot be after work hours")

        true ->
          changeset
      end
    else
      nil ->
        Changeset.add_error(changeset, :base, "Work hours not found")

      _other ->
        changeset
    end
  end

  defp validate_no_break_overlap(changeset, weekly_availability_id, exclude_break_id \\ nil) do
    start_time = Changeset.get_field(changeset, :start_time)
    end_time = Changeset.get_field(changeset, :end_time)

    if start_time && end_time do
      existing_breaks =
        AvailabilityBreakQueries.get_existing_breaks_for_validation(
          weekly_availability_id,
          exclude_break_id
        )

      if has_overlap?(start_time, end_time, existing_breaks, exclude_break_id) do
        Changeset.add_error(changeset, :base, "Break times overlap with existing break")
      else
        changeset
      end
    else
      changeset
    end
  end

  defp has_overlap?(start_time, end_time, existing_breaks, exclude_break_id) do
    Enum.any?(existing_breaks, fn
      {break_id, _break_start, _break_end} when break_id == exclude_break_id ->
        false

      {_break_id, break_start, break_end} ->
        TimeRange.overlaps?(start_time, end_time, break_start, break_end)
    end)
  end

  @doc """
  Gets common break duration presets.
  """
  @spec get_break_duration_presets() :: list({String.t(), integer()})
  def get_break_duration_presets do
    [
      {"15 minutes", 15},
      {"30 minutes", 30},
      {"45 minutes", 45},
      {"1 hour", 60},
      {"1.5 hours", 90},
      {"2 hours", 120}
    ]
  end
end
