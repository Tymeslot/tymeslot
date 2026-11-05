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
  starts on. A window is at most 24 hours, so a slot longer than that is
  refused with `:too_long`, and a slot that would widen the day past it with
  `:widened_too_long`.

  `restore/2` puts back only hours the opening left as it wrote them: when
  the day (or, for every week, the widened date too) holds other hours by
  then, or a break added since would fall outside the hours put back, it
  refuses with `:changed` and writes nothing, so an undo never overwrites a
  newer change.

  Each opening and each restore runs in one transaction that locks the
  weekday row and the date's override it reads, so a change made meanwhile
  either lands before the read (and is seen) or waits for the commit, and a
  write refused part way leaves nothing behind. Booking pages are told once,
  after the commit.
  """

  alias Tymeslot.Availability
  alias Tymeslot.Availability.AvailabilityActions
  alias Tymeslot.Availability.AvailabilityScheduleQueries
  alias Tymeslot.Availability.DateOverrides
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.Availability.Window
  alias Tymeslot.Clock
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Profiles
  alias Tymeslot.Repo

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

  @type hours :: %{start_time: Time.t(), end_time: Time.t(), ends_next_day: boolean()}

  @type weekly_previous :: %{
          is_available: boolean(),
          start_time: Time.t() | nil,
          end_time: Time.t() | nil,
          ends_next_day: boolean(),
          override: %{date: Date.t(), was: override_snapshot(), hours: hours()} | nil
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
          | :widened_too_long
          | :changed
          | :breaks_outside_hours
          | :invalid_hours

  @doc """
  Opens `start_at..end_at` for the meeting type on that date only. The
  result names the hours the date now has and what it had before.

  Takes `timezone:`, the zone the caller read the slot on (the calendar
  surface's), so the hours written are the ones it shows; the organiser's
  own zone otherwise.
  """
  @spec open_once(pos_integer(), pos_integer(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, once()} | {:error, reason()}
  def open_once(
        user_id,
        meeting_type_id,
        %DateTime{} = start_at,
        %DateTime{} = end_at,
        opts \\ []
      ) do
    with {:ok, ctx} <- context(user_id, meeting_type_id, opts),
         {:ok, slot} <- slot(ctx.timezone, start_at, end_at) do
      atomically(user_id, fn ->
        row = WeeklySchedule.lock_day_availability(ctx.schedule.id, Date.day_of_week(slot.date))

        with {:ok, current} <- DateOverrides.lock(ctx.profile.id, ctx.schedule.id, slot.date),
             {:ok, hours} <- cover(once_hours(current, row), slot),
             {:ok, _override} <- write_once(ctx, slot.date, hours, current) do
          {:ok,
           Map.merge(hours, %{
             kind: :once,
             schedule_id: ctx.schedule.id,
             date: slot.date,
             previous: override_snapshot(current)
           })}
        end
      end)
    end
  end

  @doc """
  Opens `start_at..end_at` for the meeting type on that weekday, every week.
  The result names the weekday's new hours and what it had before. When the
  slot's own date has an override that closes it or has hours of its own, that
  override is widened the same way (it would otherwise keep this week's date
  shut), and `previous.override` holds what it was. Both land or neither
  does. Takes `timezone:` as `open_once/5` does.
  """
  @spec open_weekly(pos_integer(), pos_integer(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, weekly()} | {:error, reason()}
  def open_weekly(
        user_id,
        meeting_type_id,
        %DateTime{} = start_at,
        %DateTime{} = end_at,
        opts \\ []
      ) do
    with {:ok, ctx} <- context(user_id, meeting_type_id, opts),
         {:ok, slot} <- slot(ctx.timezone, start_at, end_at) do
      day = Date.day_of_week(slot.date)

      atomically(user_id, fn ->
        row = WeeklySchedule.lock_day_availability(ctx.schedule.id, day)

        with {:ok, hours} <- cover(weekly_hours(row), slot),
             {:ok, dated} <- dated_hours(ctx, slot, row),
             {:ok, _row} <- write_weekly(ctx.profile.id, ctx.schedule.id, day, hours),
             {:ok, override} <- widen_date(ctx, slot.date, dated) do
          {:ok,
           Map.merge(hours, %{
             kind: :weekly,
             schedule_id: ctx.schedule.id,
             day_of_week: day,
             previous: row |> weekly_snapshot() |> Map.put(:override, override)
           })}
        end
      end)
    end
  end

  # The slot's date has its own say only when an override closes it or gives
  # it hours; `available` without hours follows the weekly row.
  defp dated_hours(ctx, slot, row) do
    with {:ok, current} <- DateOverrides.lock(ctx.profile.id, ctx.schedule.id, slot.date) do
      case current do
        nil ->
          {:ok, nil}

        %{override_type: :available, start_time: nil} ->
          {:ok, nil}

        _own_say ->
          with {:ok, hours} <- cover(once_hours(current, row), slot),
               do: {:ok, {current, hours}}
      end
    end
  end

  defp widen_date(_ctx, _date, nil), do: {:ok, nil}

  defp widen_date(ctx, date, {current, hours}) do
    with {:ok, _override} <- write_once(ctx, date, hours, current),
         do: {:ok, %{date: date, was: override_snapshot(current), hours: hours}}
  end

  @doc """
  Puts back what `open_once/5` or `open_weekly/5` changed: the date's old
  override (or none), or the weekday's old hours (or closed) and the widened
  date's old override. Only for the user whose schedule it is, and only
  while those hours are still the ones the opening wrote, and no break added
  to the weekday since would fall outside the hours put back: otherwise
  `{:error, :changed}`. Whatever it refuses, nothing is written.
  """
  @spec restore(pos_integer(), once() | weekly()) :: :ok | {:error, reason()}
  def restore(user_id, %{kind: :once, schedule_id: schedule_id, date: date} = result) do
    with {:ok, profile} <- profile(user_id) do
      atomically(user_id, fn ->
        with :ok <- unchanged_date(profile.id, schedule_id, date, result) do
          case result.previous do
            nil -> DateOverrides.delete(profile.id, schedule_id, date, notify: false)
            previous -> put_back_override(profile.id, schedule_id, date, previous)
          end
        end
      end)
    end
  end

  def restore(user_id, %{kind: :weekly, schedule_id: schedule_id, day_of_week: day} = result) do
    override = Map.get(result.previous, :override)

    with {:ok, profile} <- profile(user_id),
         :ok <- owned(profile.id, schedule_id) do
      atomically(user_id, fn ->
        with :ok <- unchanged_day(schedule_id, day, result),
             :ok <- unchanged_override(profile.id, schedule_id, override),
             {:ok, _row} <- restore_weekly(profile.id, schedule_id, day, result.previous) do
          case override do
            %{date: date, was: was} -> put_back_override(profile.id, schedule_id, date, was)
            nil -> :ok
          end
        end
      end)
    end
  end

  # Runs `fun` in one transaction, so its checks and writes see and leave
  # one state: the rows it locks stay as it read them until it commits, and
  # any `{:error, _}` rolls back whatever it wrote before. Booking pages are
  # told once, after the commit.
  defp atomically(user_id, fun) do
    case Repo.transaction(fn -> commit_or_roll_back(fun.()) end) do
      {:ok, outcome} ->
        Availability.changed(user_id)
        outcome

      {:error, _reason} = error ->
        error
    end
  end

  defp commit_or_roll_back({:error, reason}), do: Repo.rollback(reason)
  defp commit_or_roll_back(outcome), do: outcome

  defp owned(profile_id, schedule_id) do
    case AvailabilityScheduleQueries.get_for_profile(schedule_id, profile_id) do
      nil -> {:error, :not_found}
      _schedule -> :ok
    end
  end

  # The weekday still holds the hours the opening gave it.
  defp unchanged_day(schedule_id, day, hours) do
    case WeeklySchedule.lock_day_availability(schedule_id, day) do
      %{is_available: true} = row -> same_hours(row, hours)
      _closed_or_gone -> {:error, :changed}
    end
  end

  defp unchanged_override(_profile_id, _schedule_id, nil), do: :ok

  defp unchanged_override(profile_id, schedule_id, %{date: date, hours: hours}),
    do: unchanged_date(profile_id, schedule_id, date, hours)

  # The date still holds the custom hours the opening wrote for it.
  defp unchanged_date(profile_id, schedule_id, date, hours) do
    case DateOverrides.lock(profile_id, schedule_id, date) do
      {:ok, %{override_type: :custom_hours} = override} -> same_hours(override, hours)
      {:ok, _other_or_none} -> {:error, :changed}
      {:error, _reason} = error -> error
    end
  end

  defp same_hours(window, hours) do
    same? =
      match?(%Time{}, window.start_time) and match?(%Time{}, window.end_time) and
        minutes(window.start_time) == minutes(hours.start_time) and
        minutes(window.end_time) == minutes(hours.end_time) and
        window.ends_next_day == true == hours.ends_next_day

    if same?, do: :ok, else: {:error, :changed}
  end

  # The weekday exactly as it was, closed or open: a closed day keeps the
  # hours it stored and the breaks it holds. A break that would fall outside
  # those hours was added since the opening, so the day has changed.
  defp restore_weekly(profile_id, schedule_id, day, previous) do
    profile_id
    |> AvailabilityActions.restore_day(
      schedule_id,
      day,
      Map.take(previous, [:is_available, :start_time, :end_time, :ends_next_day]),
      notify: false
    )
    |> stranded_as_changed()
    |> map_write_error()
  end

  defp stranded_as_changed({:error, {:breaks_outside_hours, _breaks}}), do: {:error, :changed}
  defp stranded_as_changed(result), do: result

  # An undo is not a new write: the date may have passed since, and its old
  # hours are still what it held.
  defp put_back_override(profile_id, schedule_id, date, snapshot) do
    profile_id
    |> DateOverrides.put_back(schedule_id, Map.put(snapshot, :date, date), notify: false)
    |> map_write_error()
    |> to_ok()
  end

  defp write_once(ctx, date, hours, current) do
    attrs =
      Map.merge(hours, %{
        date: date,
        override_type: :custom_hours,
        reason: current && current.reason
      })

    ctx.profile.id
    |> DateOverrides.upsert(ctx.schedule.id, attrs, notify: false)
    |> map_write_error()
  end

  defp write_weekly(profile_id, schedule_id, day, hours) do
    profile_id
    |> AvailabilityActions.update_day_hours(
      schedule_id,
      day,
      Calendar.strftime(hours.start_time, "%H:%M"),
      Window.format_end(hours.end_time, hours.ends_next_day),
      notify: false
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
  # schedule it books against must be the user's own. The slot is read on
  # the zone the caller names, else the organiser's.
  defp context(user_id, meeting_type_id, opts)
       when is_integer(user_id) and is_integer(meeting_type_id) do
    with %MeetingTypeSchema{is_active: true, is_archived: false} = meeting_type <-
           MeetingTypes.get_meeting_type(meeting_type_id, user_id),
         {:ok, %{id: profile_id} = profile} <- profile(user_id),
         %{profile_id: ^profile_id} = schedule <- Schedules.resolve_for(meeting_type, profile) do
      timezone = Keyword.get_lazy(opts, :timezone, fn -> Profiles.timezone(profile) end)
      {:ok, %{profile: profile, schedule: schedule, timezone: timezone}}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp context(_user_id, _meeting_type_id, _opts), do: {:error, :not_found}

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
  defp once_hours(%{override_type: :unavailable}, _row), do: nil

  defp once_hours(%{start_time: %Time{}, end_time: %Time{}} = override, _row),
    do: span(override)

  defp once_hours(_usual_hours, row), do: weekly_hours(row)

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

    if to - from > @day_minutes, do: {:error, :widened_too_long}, else: hours(from, to)
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
