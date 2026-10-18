defmodule Tymeslot.Availability.Opening do
  @moduledoc """
  "Open for booking" from the calendar: makes a slot the organiser picked
  bookable for a meeting type, just this once or every week, and puts the
  schedule back for undo.

  The schedule changed is the one the meeting type books against
  (`Tymeslot.Availability.Schedules.resolve_for/2`). A schedule holds one
  window per weekday and one override per date, so opening never adds a
  second window: it widens the day's window to the smallest one covering
  both the hours already open and the slot, and any time between them opens
  too. A day with nothing open (closed, or an `unavailable` override) opens
  on exactly the slot. Just this once writes a `custom_hours` override for
  that date; every week widens the weekday's row through
  `Tymeslot.Availability.AvailabilityActions`.

  Times are read on the organiser's clock, and a slot belongs to the date it
  starts on. A window is at most 24 hours, so a slot or a widened window
  longer than that is refused with `:too_long`.
  """

  alias Tymeslot.Availability.AvailabilityActions
  alias Tymeslot.Availability.DateOverrides
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.Availability.Window
  alias Tymeslot.Clock
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Profiles

  @day_minutes 1440

  @type override_snapshot :: %{
          override_type: String.t(),
          start_time: Time.t() | nil,
          end_time: Time.t() | nil,
          ends_next_day: boolean(),
          reason: String.t() | nil
        }

  @type weekly_snapshot :: %{
          is_available: boolean(),
          start_time: Time.t() | nil,
          end_time: Time.t() | nil,
          ends_next_day: boolean()
        }

  @type once :: %{
          kind: :once,
          schedule_id: integer(),
          date: Date.t(),
          start_time: Time.t(),
          end_time: Time.t(),
          ends_next_day: boolean(),
          previous: override_snapshot() | nil
        }

  @type weekly_previous :: %{
          is_available: boolean(),
          start_time: Time.t() | nil,
          end_time: Time.t() | nil,
          ends_next_day: boolean(),
          override: %{date: Date.t(), was: override_snapshot()} | nil
        }

  @type weekly :: %{
          kind: :weekly,
          schedule_id: integer(),
          day_of_week: 1..7,
          start_time: Time.t(),
          end_time: Time.t(),
          ends_next_day: boolean(),
          previous: weekly_previous()
        }

  @type reason ::
          :not_found
          | :invalid_range
          | :in_past
          | :too_long
          | :breaks_outside_hours
          | :invalid_hours

  @doc """
  Opens `start_at..end_at` for the meeting type on that date only. The
  result names the hours the date now has and what it had before.
  """
  @spec open_once(pos_integer(), pos_integer(), DateTime.t(), DateTime.t()) ::
          {:ok, once()} | {:error, reason()}
  def open_once(user_id, meeting_type_id, %DateTime{} = start_at, %DateTime{} = end_at) do
    with {:ok, ctx} <- context(user_id, meeting_type_id),
         {:ok, slot} <- slot(ctx.timezone, start_at, end_at),
         {:ok, current} <- DateOverrides.get(ctx.profile.id, ctx.schedule.id, slot.date),
         {:ok, hours} <- cover(once_hours(current, ctx.schedule.id, slot.date), slot),
         {:ok, _override} <- write_once(ctx, slot.date, hours, current) do
      {:ok,
       Map.merge(hours, %{
         kind: :once,
         schedule_id: ctx.schedule.id,
         date: slot.date,
         previous: override_snapshot(current)
       })}
    end
  end

  @doc """
  Opens `start_at..end_at` for the meeting type on that weekday, every week.
  The result names the weekday's new hours and what it had before. When the
  slot's own date has an override that closes it or has hours of its own, that
  override is widened the same way (it would otherwise keep this week's date
  shut), and `previous.override` holds what it was.
  """
  @spec open_weekly(pos_integer(), pos_integer(), DateTime.t(), DateTime.t()) ::
          {:ok, weekly()} | {:error, reason()}
  def open_weekly(user_id, meeting_type_id, %DateTime{} = start_at, %DateTime{} = end_at) do
    with {:ok, ctx} <- context(user_id, meeting_type_id),
         {:ok, slot} <- slot(ctx.timezone, start_at, end_at) do
      day = Date.day_of_week(slot.date)
      row = WeeklySchedule.get_day_availability(ctx.schedule.id, day)

      with {:ok, hours} <- cover(weekly_hours(row), slot),
           {:ok, dated} <- dated_hours(ctx, slot),
           {:ok, _row} <- write_weekly(ctx.profile.id, ctx.schedule.id, day, hours),
           {:ok, override} <- widen_date(ctx, slot.date, dated, row) do
        {:ok,
         Map.merge(hours, %{
           kind: :weekly,
           schedule_id: ctx.schedule.id,
           day_of_week: day,
           previous: row |> weekly_snapshot() |> Map.put(:override, override)
         })}
      end
    end
  end

  # The slot's date has its own say only when an override closes it or gives
  # it hours; `available` without hours follows the weekly row.
  defp dated_hours(ctx, slot) do
    with {:ok, current} <- DateOverrides.get(ctx.profile.id, ctx.schedule.id, slot.date) do
      case current do
        nil ->
          {:ok, nil}

        %{override_type: "available", start_time: nil} ->
          {:ok, nil}

        _own_say ->
          with {:ok, hours} <- cover(once_hours(current, ctx.schedule.id, slot.date), slot),
               do: {:ok, {current, hours}}
      end
    end
  end

  defp widen_date(_ctx, _date, nil, _row), do: {:ok, nil}

  defp widen_date(ctx, date, {current, hours}, row) do
    case write_once(ctx, date, hours, current) do
      {:ok, _override} ->
        {:ok, %{date: date, was: override_snapshot(current)}}

      {:error, _reason} = error ->
        # The weekday is already widened; put it back so nothing half-applies.
        restore_weekly(
          ctx.profile.id,
          ctx.schedule.id,
          Date.day_of_week(date),
          weekly_snapshot(row)
        )

        error
    end
  end

  @doc """
  Puts back what `open_once/4` or `open_weekly/4` changed: the date's old
  override (or none), or the weekday's old hours (or closed). Only for the
  user whose schedule it is.
  """
  @spec restore(pos_integer(), once() | weekly()) :: :ok | {:error, reason()}
  def restore(user_id, %{kind: :once, schedule_id: schedule_id, date: date, previous: nil}) do
    with {:ok, profile} <- profile(user_id) do
      DateOverrides.delete(profile.id, schedule_id, date)
    end
  end

  def restore(user_id, %{kind: :once, schedule_id: schedule_id, date: date, previous: previous}) do
    with {:ok, profile} <- profile(user_id) do
      profile.id
      |> put_back_override(schedule_id, date, previous)
      |> to_ok()
    end
  end

  def restore(user_id, %{kind: :weekly, schedule_id: schedule_id, day_of_week: day} = result) do
    with {:ok, profile} <- profile(user_id),
         {:ok, _row} <- restore_weekly(profile.id, schedule_id, day, result.previous) do
      case result.previous do
        %{override: %{date: date, was: was}} ->
          profile.id |> put_back_override(schedule_id, date, was) |> to_ok()

        _no_override ->
          :ok
      end
    else
      {:error, _reason} = error -> map_write_error(error)
    end
  end

  # The weekday exactly as it was, closed or open: a closed day keeps the
  # hours it stored and the breaks it holds.
  defp restore_weekly(profile_id, schedule_id, day, previous) do
    profile_id
    |> AvailabilityActions.restore_day(
      schedule_id,
      day,
      Map.take(previous, [:is_available, :start_time, :end_time, :ends_next_day])
    )
    |> map_write_error()
  end

  # An undo is not a new write: the date may have passed since, and its old
  # hours are still what it held.
  defp put_back_override(profile_id, schedule_id, date, snapshot) do
    profile_id
    |> DateOverrides.put_back(schedule_id, Map.put(snapshot, :date, date))
    |> map_write_error()
  end

  defp write_once(ctx, date, hours, current) do
    attrs =
      Map.merge(hours, %{
        date: date,
        override_type: "custom_hours",
        reason: current && current.reason
      })

    ctx.profile.id
    |> DateOverrides.upsert(ctx.schedule.id, attrs)
    |> map_write_error()
  end

  defp write_weekly(profile_id, schedule_id, day, hours) do
    profile_id
    |> AvailabilityActions.update_day_hours(
      schedule_id,
      day,
      Calendar.strftime(hours.start_time, "%H:%M"),
      Window.format_end(hours.end_time, hours.ends_next_day)
    )
    |> map_write_error()
  end

  defp map_write_error({:error, %Ecto.Changeset{}}), do: {:error, :invalid_hours}
  defp map_write_error({:error, :invalid_time_format}), do: {:error, :invalid_hours}

  defp map_write_error({:error, {:breaks_outside_hours, _breaks}}),
    do: {:error, :breaks_outside_hours}

  defp map_write_error(result), do: result

  defp to_ok({:ok, _value}), do: :ok
  defp to_ok({:error, _reason} = error), do: error

  # The meeting type must be the user's, active and not archived, and the
  # schedule it books against must be the user's own.
  defp context(user_id, meeting_type_id)
       when is_integer(user_id) and is_integer(meeting_type_id) do
    with %MeetingTypeSchema{is_active: true, is_archived: false} = meeting_type <-
           MeetingTypes.get_meeting_type(meeting_type_id, user_id),
         {:ok, %{id: profile_id} = profile} <- profile(user_id),
         %{profile_id: ^profile_id} = schedule <- Schedules.resolve_for(meeting_type, profile) do
      {:ok, %{profile: profile, schedule: schedule, timezone: Profiles.timezone(profile)}}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp context(_user_id, _meeting_type_id), do: {:error, :not_found}

  defp profile(user_id), do: Profiles.get_profile_by_user_id(user_id)

  # The slot as minutes from the owner-local midnight of the date it starts
  # on; an end on the next day reads past 1440.
  defp slot(timezone, start_at, end_at) do
    local_start = DateTime.shift_zone!(start_at, timezone)
    local_end = DateTime.shift_zone!(end_at, timezone)
    date = DateTime.to_date(local_start)
    from = minutes(local_start)
    to = Date.diff(DateTime.to_date(local_end), date) * @day_minutes + minutes(local_end)

    cond do
      DateTime.compare(end_at, start_at) != :gt -> {:error, :invalid_range}
      DateTime.compare(end_at, Clock.utc_now()) != :gt -> {:error, :in_past}
      to - from > @day_minutes -> {:error, :too_long}
      true -> {:ok, %{date: date, from: from, to: to}}
    end
  end

  # The hours the date has open now, read as the slot engine reads them
  # (`BusinessHours`): an override with hours of its own wins, `unavailable`
  # closes the day, and `available` without hours or no override at all
  # falls back to the weekly row.
  defp once_hours(%{override_type: "unavailable"}, _schedule_id, _date), do: nil

  defp once_hours(%{start_time: %Time{}, end_time: %Time{}} = override, _schedule_id, _date),
    do: span(override)

  defp once_hours(_usual_hours, schedule_id, date) do
    schedule_id
    |> WeeklySchedule.get_day_availability(Date.day_of_week(date))
    |> weekly_hours()
  end

  defp weekly_hours(%{is_available: true, start_time: %Time{}, end_time: %Time{}} = row),
    do: span(row)

  defp weekly_hours(_closed), do: nil

  defp span(%{start_time: start_time, end_time: end_time} = window) do
    next_day = if window.ends_next_day == true, do: @day_minutes, else: 0
    %{from: minutes(start_time), to: minutes(end_time) + next_day}
  end

  defp cover(nil, slot), do: hours(slot.from, slot.to)

  defp cover(%{from: open_from, to: open_to}, slot) do
    from = min(open_from, slot.from)
    to = max(open_to, slot.to)

    if to - from > @day_minutes, do: {:error, :too_long}, else: hours(from, to)
  end

  defp hours(from, to) do
    {:ok,
     %{
       start_time: clock(from),
       end_time: clock(rem(to, @day_minutes)),
       ends_next_day: to >= @day_minutes
     }}
  end

  defp clock(minutes), do: Time.new!(div(minutes, 60), rem(minutes, 60), 0)

  defp minutes(%{hour: hour, minute: minute}), do: hour * 60 + minute

  defp override_snapshot(nil), do: nil

  defp override_snapshot(override),
    do: Map.take(override, [:override_type, :start_time, :end_time, :ends_next_day, :reason])

  defp weekly_snapshot(nil),
    do: %{is_available: false, start_time: nil, end_time: nil, ends_next_day: false}

  defp weekly_snapshot(row) do
    %{
      is_available: row.is_available == true,
      start_time: row.start_time,
      end_time: row.end_time,
      ends_next_day: row.ends_next_day == true
    }
  end
end
