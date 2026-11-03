defmodule Tymeslot.Availability.ExtraAvailability do
  @moduledoc """
  Extra available times on a schedule: a date with a from and a to time,
  open in addition to whatever the weekly hours open that day.

  They make a schedule without a regular pattern possible: every weekday
  switched off and only the dates listed here open, such as office hours held
  once a month. A date may hold several, as long as they do not overlap; a
  time on a weekday that is already open simply adds to its hours.

  They belong to one schedule, so they reach exactly the meeting types booked
  against it, and they are stored as `availability_overrides` rows of type
  `extra_hours`. Time off and an `unavailable` override on the date still
  outrank them: either closes an extra time too. Past dates are deleted by
  the daily retention run (`prune_past/1`).
  """

  alias Ecto.Changeset
  alias Tymeslot.Availability
  alias Tymeslot.Availability.{AvailabilityOverrideQueries, AvailabilityOverrideSchema}
  alias Tymeslot.Availability.AvailabilityScheduleSchema

  @type_name :extra_hours
  # Plenty for office hours a few times a month for a year or more, and a
  # bound on what a schedule's slot calculation has to read.
  @max_per_schedule 100

  @spec max_per_schedule() :: pos_integer()
  def max_per_schedule, do: @max_per_schedule

  @doc "The schedule's extra times from `today` on, in date and time order."
  @spec list_upcoming(integer(), Date.t()) :: [AvailabilityOverrideSchema.t()]
  def list_upcoming(schedule_id, %Date{} = today),
    do: AvailabilityOverrideQueries.list_extra_from(schedule_id, today)

  @doc """
  Adds an extra time to `schedule` from `attrs` (`date`, `start_time`,
  `end_time`), judged against `today` in the owner's timezone.

  Refuses a date in the past (`:in_past`), a time that overlaps another extra
  time on the same date (`:overlap`), and more than `max_per_schedule/0`
  (`:too_many`); an invalid time range comes back as the changeset.
  """
  @spec add(AvailabilityScheduleSchema.t(), map(), Date.t()) ::
          {:ok, AvailabilityOverrideSchema.t()}
          | {:error, :in_past | :overlap | :too_many | Changeset.t()}
  def add(%AvailabilityScheduleSchema{} = schedule, attrs, %Date{} = today) do
    changeset =
      AvailabilityOverrideSchema.changeset(%AvailabilityOverrideSchema{}, %{
        schedule_id: schedule.id,
        override_type: @type_name,
        date: fetch(attrs, :date),
        start_time: fetch(attrs, :start_time),
        end_time: fetch(attrs, :end_time),
        ends_next_day: false
      })

    with {:ok, extra} <- Changeset.apply_action(changeset, :insert),
         :ok <- ensure_not_past(extra, today),
         :ok <- ensure_room(schedule),
         :ok <- ensure_no_overlap(extra) do
      changeset
      |> AvailabilityOverrideQueries.insert()
      |> invalidate(schedule)
    end
  end

  @doc "Deletes one of `schedule`'s extra times."
  @spec delete(AvailabilityScheduleSchema.t(), integer() | String.t()) ::
          {:ok, AvailabilityOverrideSchema.t()} | {:error, :not_found | Changeset.t()}
  def delete(%AvailabilityScheduleSchema{} = schedule, id) do
    case AvailabilityOverrideQueries.get_extra(schedule.id, to_integer(id)) do
      nil -> {:error, :not_found}
      extra -> extra |> AvailabilityOverrideQueries.delete() |> invalidate(schedule)
    end
  end

  @doc """
  Deletes every schedule's extra times on dates before `date`. Run daily by
  `Tymeslot.Workers.DataRetentionWorker` with yesterday's UTC date, so a time
  that is still today somewhere is never removed.
  """
  @spec prune_past(Date.t()) :: {non_neg_integer(), nil}
  def prune_past(%Date{} = date), do: AvailabilityOverrideQueries.delete_extra_before(date)

  @doc """
  The extra times of `schedule_id` on `date` as windows, read from the
  overrides `config` already holds when it has them.
  """
  @spec windows_on(Date.t(), integer(), map()) :: [map()]
  def windows_on(date, schedule_id, %{overrides: overrides}) when is_list(overrides) do
    overrides
    |> Enum.filter(
      &(&1.override_type == @type_name and &1.date == date and &1.schedule_id == schedule_id)
    )
    |> Enum.sort_by(& &1.start_time, Time)
  end

  def windows_on(date, schedule_id, _config),
    do: AvailabilityOverrideQueries.list_extra_on(schedule_id, date)

  defp ensure_not_past(%{date: date}, today) do
    if Date.compare(date, today) == :lt, do: {:error, :in_past}, else: :ok
  end

  defp ensure_room(schedule) do
    if AvailabilityOverrideQueries.count_extra(schedule.id) < @max_per_schedule,
      do: :ok,
      else: {:error, :too_many}
  end

  defp ensure_no_overlap(extra) do
    clash? =
      extra.schedule_id
      |> AvailabilityOverrideQueries.list_extra_on(extra.date)
      |> Enum.any?(fn other ->
        Time.compare(extra.start_time, other.end_time) == :lt and
          Time.compare(other.start_time, extra.end_time) == :lt
      end)

    if clash?, do: {:error, :overlap}, else: :ok
  end

  defp invalidate({:ok, _row} = result, schedule) do
    Availability.changed(schedule)
    result
  end

  defp invalidate(error, _schedule), do: error

  defp fetch(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp to_integer(id) when is_integer(id), do: id

  defp to_integer(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _invalid -> -1
    end
  end
end
