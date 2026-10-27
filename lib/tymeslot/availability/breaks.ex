defmodule Tymeslot.Availability.Breaks do
  @moduledoc """
  Context for managing availability breaks.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Ecto.Changeset
  alias Tymeslot.Availability.AvailabilityBreakQueries
  alias Tymeslot.Availability.AvailabilityBreakSchema
  alias Tymeslot.Availability.WeeklyAvailabilityQueries
  alias Tymeslot.Availability.Window

  @doc """
  Adds a new break to a day.
  """
  @spec add_break(integer(), Time.t(), Time.t(), String.t() | nil) ::
          {:ok, AvailabilityBreakSchema.t()} | {:error, Ecto.Changeset.t()}
  def add_break(weekly_availability_id, start_time, end_time, label) do
    # Get the next sort order
    next_sort_order = AvailabilityBreakQueries.get_next_sort_order(weekly_availability_id)

    attrs = %{
      weekly_availability_id: weekly_availability_id,
      start_time: start_time,
      end_time: end_time,
      label: label,
      sort_order: next_sort_order
    }

    work_hours = AvailabilityBreakQueries.get_work_hours(weekly_availability_id)

    %AvailabilityBreakSchema{}
    |> AvailabilityBreakSchema.changeset(attrs, work_hours: work_hours)
    |> require_work_hours(work_hours)
    |> validate_no_break_overlap(weekly_availability_id, work_hours)
    |> AvailabilityBreakQueries.insert_changeset()
  end

  @doc """
  The breaks among `breaks` that would fall outside `work_hours` (a day's
  `start_time`, `end_time` and `ends_next_day`), in the order given. A day
  without hours has nothing to fall outside of.
  """
  @spec outside_hours([map()], map()) :: [map()]
  def outside_hours(breaks, %{start_time: %Time{}, end_time: %Time{}} = work_hours) do
    # `break_within?/3` also refuses a break whose end reads as before its
    # start in these hours: one that crossed midnight in overnight hours that
    # no longer run past midnight.
    Enum.reject(breaks, &Window.break_within?(work_hours, &1.start_time, &1.end_time))
  end

  def outside_hours(_breaks, _no_hours), do: []

  @doc """
  Replaces a day's breaks with copies of `breaks` (anything carrying
  `start_time`, `end_time`, `label` and `sort_order`), each validated against
  that day's hours like a break added by hand.

  Run it inside the caller's transaction: on the first refused copy it returns
  `{:error, {:break_outside_hours, day, break}}` (the copy falls outside the
  day's hours, as a break saved before its day's hours were narrowed can) or
  `{:error, changeset}`, and leaves the rollback to the caller. Copies are
  checked against the day's hours, not against each other: they come from a
  day whose breaks were already checked for overlap.
  """
  @spec replace_breaks(map(), [map()]) ::
          :ok | {:error, {:break_outside_hours, map(), map()} | Ecto.Changeset.t()}
  def replace_breaks(%{id: _id} = day, breaks) when is_list(breaks) do
    work_hours = Map.take(day, [:start_time, :end_time, :ends_next_day])

    case outside_hours(breaks, work_hours) do
      [] -> insert_copies(day, breaks, work_hours)
      [break | _others] -> {:error, {:break_outside_hours, day, break}}
    end
  end

  defp insert_copies(%{id: weekly_availability_id}, breaks, work_hours) do
    AvailabilityBreakQueries.delete_for_day(weekly_availability_id)

    Enum.reduce_while(breaks, :ok, fn break, :ok ->
      attrs = %{
        weekly_availability_id: weekly_availability_id,
        start_time: break.start_time,
        end_time: break.end_time,
        label: break.label,
        sort_order: break.sort_order
      }

      changeset =
        AvailabilityBreakSchema.changeset(%AvailabilityBreakSchema{}, attrs,
          work_hours: work_hours
        )

      case AvailabilityBreakQueries.insert_changeset(changeset) do
        {:ok, _break} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
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
  Adds a quick break with predefined duration.
  """
  @spec add_quick_break(integer(), Time.t(), integer(), String.t() | nil) ::
          {:ok, AvailabilityBreakSchema.t()} | {:error, Ecto.Changeset.t() | String.t()}
  def add_quick_break(weekly_availability_id, start_time, duration_minutes, label \\ nil)
      when is_integer(duration_minutes) and duration_minutes > 0 do
    # Time.add/3 wraps at midnight, which is exactly what a break inside an
    # overnight window needs; inside a same-day window the wrapped end lands
    # before the start and the within-hours rule refuses it.
    end_time = Time.add(start_time, duration_minutes * 60, :second)
    add_break(weekly_availability_id, start_time, end_time, label)
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

  # The within-hours rule itself is the changeset's, given the hours; a day
  # with no row to read them from cannot take a break.
  defp require_work_hours(changeset, %{}), do: changeset

  defp require_work_hours(changeset, nil),
    do: Changeset.add_error(changeset, :base, dgettext_noop("errors", "Work hours not found"))

  defp validate_no_break_overlap(changeset, weekly_availability_id, window) do
    start_time = Changeset.get_field(changeset, :start_time)
    end_time = Changeset.get_field(changeset, :end_time)

    if start_time && end_time do
      existing_breaks =
        AvailabilityBreakQueries.get_existing_breaks_for_validation(weekly_availability_id)

      if has_overlap?(window, {start_time, end_time}, existing_breaks) do
        Changeset.add_error(
          changeset,
          :base,
          dgettext_noop("errors", "Break times overlap with existing break")
        )
      else
        changeset
      end
    else
      changeset
    end
  end

  defp has_overlap?(window, {start_time, end_time}, existing_breaks) do
    {from, to} = offsets(window, start_time, end_time)

    Enum.any?(existing_breaks, fn {_break_id, break_start, break_end} ->
      {other_from, other_to} = offsets(window, break_start, break_end)
      from < other_to and to > other_from
    end)
  end

  # Without hours to measure from, a break is compared on its own clock, as
  # before.
  defp offsets(%{start_time: %Time{}, end_time: %Time{}} = window, start_time, end_time),
    do: Window.break_offsets(window, start_time, end_time)

  defp offsets(_no_hours, start_time, end_time),
    do: {Time.diff(start_time, ~T[00:00:00]), Time.diff(end_time, ~T[00:00:00])}

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
