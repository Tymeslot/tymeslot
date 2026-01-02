defmodule Tymeslot.Availability.Breaks do
  @moduledoc """
  Context for managing availability breaks.
  """

  alias Ecto.Changeset
  alias Tymeslot.DatabaseQueries.AvailabilityBreakQueries
  alias Tymeslot.DatabaseSchemas.AvailabilityBreakSchema
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
  Deletes a break.
  """
  @spec delete_break(integer()) :: {:ok, AvailabilityBreakSchema.t()} | {:error, String.t()}
  def delete_break(break_id) do
    case AvailabilityBreakQueries.get_break(break_id) do
      nil ->
        {:error, "Break not found"}

      break ->
        AvailabilityBreakQueries.delete_break(break)
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
  def add_quick_break(weekly_availability_id, start_time, duration_minutes, label \\ nil) do
    end_time = Time.add(start_time, duration_minutes * 60, :second)
    add_break(weekly_availability_id, start_time, end_time, label)
  rescue
    _ ->
      {:error, "Invalid time calculation"}
  end

  @doc """
  Validates that break times don't overlap with existing breaks.
  """
  @spec validate_break_times(Time.t(), Time.t(), Time.t(), Time.t(), list(), integer() | nil) ::
          :ok | {:error, String.t()}
  def validate_break_times(
        start_time,
        end_time,
        work_start,
        work_end,
        existing_breaks,
        exclude_break_id \\ nil
      ) do
    cond do
      Time.compare(start_time, end_time) != :lt ->
        {:error, "End time must be after start time"}

      Time.compare(start_time, work_start) == :lt ->
        {:error, "Break cannot start before work hours"}

      Time.compare(end_time, work_end) == :gt ->
        {:error, "Break cannot end after work hours"}

      has_overlap?(start_time, end_time, existing_breaks, exclude_break_id) ->
        {:error, "Break overlaps with existing break"}

      true ->
        :ok
    end
  end

  # Private functions

  defp validate_break_within_work_hours(changeset, weekly_availability_id) do
    with {work_start, work_end} <-
           AvailabilityBreakQueries.get_work_hours(weekly_availability_id),
         start_time when not is_nil(start_time) <- Changeset.get_field(changeset, :start_time),
         end_time when not is_nil(end_time) <- Changeset.get_field(changeset, :end_time) do
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

      _ ->
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
        times_overlap?(start_time, end_time, break_start, break_end)
    end)
  end

  defp times_overlap?(start1, end1, start2, end2) do
    TimeRange.overlaps?(start1, end1, start2, end2)
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
