defmodule Tymeslot.CalendarGrid.EventVideoRooms do
  @moduledoc """
  Keeps track of the video rooms made for events created on the dashboard
  calendar grid, so the rooms that would otherwise stay on the organiser's
  server for ever are deleted.

  A booking's room is held by its `meetings` row, which every clean-up path
  works from. A grid event lives only in the organiser's calendar, so for a
  provider whose rooms persist until something deletes them
  (`ProviderConfig.rooms_deleted_after_meeting/0`) the room is recorded here
  when it is made. The record follows the event through the grid: moving the
  event moves the record's times, and the room's lobby with them; deleting the
  event deletes the room. `Tymeslot.Workers.ExpiredVideoRoomCleanupWorker`
  deletes rooms some days after their event has ended, and disconnecting the
  integration with its rooms deletes them too.

  The room is never read back out of the event's description or location. The
  organiser can edit that text in any calendar client, and a room found there
  need not be one Tymeslot created.

  ## When a room stops being needed

  A one-off event's room is needed until the event ends. An all-day event is
  given the whole day after its exclusive end date, which covers every
  timezone. A recurring series is given a time no occurrence can end after,
  worked out from its `UNTIL` or `COUNT`; a series with no end, or a rule
  beyond what the grid's recurrence editor writes, is never treated as over.
  Editing one occurrence of a series only ever moves that time later, because
  the occurrence edited says nothing about where the series itself ends.
  """

  require Logger

  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.CalendarGrid.EventVideoRoomSchema
  alias Tymeslot.Integrations.Calendar.RecurrenceExpander
  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Workers.VideoSyncWorker

  @typedoc """
  A grid event's identity and timing. `start`/`end` are `DateTime`s for a timed
  event and `Date`s (the end exclusive) for an all-day one.
  """
  @type schedule :: %{
          required(:all_day) => boolean(),
          required(:start) => DateTime.t() | Date.t() | nil,
          required(:end) => DateTime.t() | Date.t() | nil,
          required(:recurrence_rule) => String.t() | nil
        }

  @seconds_per_day 86_400

  # The most days one repetition of each frequency can span.
  @period_days %{daily: 1, weekly: 7, monthly: 31, yearly: 366}

  # The rule parts the grid's recurrence editor writes (`RRule.build/2`). A
  # rule with any other part can space its occurrences in ways the bound below
  # does not cover, so it is treated as having no end.
  @bounded_rule_parts ~w(FREQ INTERVAL BYDAY COUNT UNTIL WKST)

  @doc """
  Records a room just made for a grid event, when its provider is one whose
  rooms Tymeslot deletes. `event` carries `:user_id`, `:video_integration_id`,
  `:calendar_integration_id`, `:uid` and the `schedule()` keys.
  """
  @spec record(map(), map()) :: :ok
  def record(%{provider_type: provider, room_data: %{room_id: room_id}}, event)
      when is_binary(room_id) and room_id != "" do
    if Atom.to_string(provider) in ProviderConfig.rooms_deleted_after_meeting() do
      insert(room_id, event)
    else
      :ok
    end
  end

  def record(_meeting_context, _event), do: :ok

  @doc """
  Brings the rooms of a grid event in step with its timing after the event
  changed, and moves each room's lobby when its start moved.
  """
  @spec rescheduled(%{
          required(:calendar_integration_id) => pos_integer(),
          required(:uid) => String.t(),
          optional(atom()) => term()
        }) :: :ok
  def rescheduled(%{calendar_integration_id: calendar_integration_id, uid: uid} = event)
      when is_integer(calendar_integration_id) and is_binary(uid) do
    calendar_integration_id
    |> EventVideoRoomQueries.list_for_event(uid)
    |> Enum.each(&reschedule_room(&1, event))
  end

  def rescheduled(_event), do: :ok

  @doc """
  Follows a grid event that moved to another calendar integration, where it
  was created afresh under a new uid.
  """
  @spec moved(pos_integer(), String.t(), pos_integer(), String.t()) :: :ok
  def moved(from_integration_id, from_uid, to_integration_id, to_uid) do
    _count =
      EventVideoRoomQueries.move_to_event(
        from_integration_id,
        from_uid,
        to_integration_id,
        to_uid
      )

    :ok
  end

  @doc """
  Deletes the rooms of a grid event that was deleted. The provider calls run in
  `Tymeslot.Workers.VideoSyncWorker`, which removes each record once its room
  is gone.
  """
  @spec event_deleted(pos_integer(), String.t()) :: :ok
  def event_deleted(calendar_integration_id, uid)
      when is_integer(calendar_integration_id) and is_binary(uid) do
    calendar_integration_id
    |> EventVideoRoomQueries.list_for_event(uid)
    |> Enum.each(&enqueue(&1, "delete"))
  end

  def event_deleted(_calendar_integration_id, _uid), do: :ok

  @doc """
  The start a room's lobby waits for and the time the room stops being needed,
  for an event with the given timing. See the module documentation.
  """
  @spec times(schedule()) :: {DateTime.t() | nil, DateTime.t() | nil}
  def times(%{recurrence_rule: rule} = schedule) when is_binary(rule) and rule != "",
    do: {nil, series_end(rule, schedule)}

  def times(%{all_day: true, end: %Date{} = end_date}),
    do: {nil, end_date |> midnight() |> DateTime.add(@seconds_per_day, :second)}

  def times(%{start: %DateTime{} = start, end: %DateTime{} = finish}),
    do: {truncate(start), truncate(finish)}

  def times(_schedule), do: {nil, nil}

  defp insert(room_id, event) do
    {starts_at, ends_at} = times(event)

    attrs = %{
      user_id: event.user_id,
      video_integration_id: event.video_integration_id,
      calendar_integration_id: event.calendar_integration_id,
      event_uid: event.uid,
      room_id: room_id,
      starts_at: starts_at,
      ends_at: ends_at
    }

    case EventVideoRoomQueries.insert(attrs) do
      {:ok, _room} ->
        :ok

      {:error, changeset} ->
        # The room exists either way; failing the event the user just created
        # over its bookkeeping would be worse than a room left to its owner.
        Logger.warning("Failed to record the video room of a calendar event",
          user_id: event.user_id,
          video_integration_id: event.video_integration_id,
          errors: inspect(changeset.errors)
        )

        :ok
    end
  end

  defp reschedule_room(%EventVideoRoomSchema{} = room, event) do
    {starts_at, ends_at} = event |> schedule_of() |> times()
    ends_at = if recurring?(event), do: later_end(room.ends_at, ends_at), else: ends_at
    update_schedule(room, starts_at, ends_at)
  end

  defp update_schedule(%{starts_at: starts_at, ends_at: ends_at}, starts_at, ends_at), do: :ok

  defp update_schedule(room, starts_at, ends_at) do
    case EventVideoRoomQueries.update_schedule(room, starts_at, ends_at) do
      {:ok, updated} ->
        maybe_move_lobby(room, updated)

      {:error, changeset} ->
        Logger.warning("Failed to update the video room of a calendar event",
          calendar_event_video_room_id: room.id,
          errors: inspect(changeset.errors)
        )

        :ok
    end
  end

  # The grid's cache rows carry dates for an all-day event and timestamps for
  # a timed one.
  defp schedule_of(%{all_day: true} = event),
    do: %{
      all_day: true,
      start: Map.get(event, :start_date),
      end: Map.get(event, :end_date),
      recurrence_rule: Map.get(event, :recurrence_rule)
    }

  defp schedule_of(event),
    do: %{
      all_day: false,
      start: Map.get(event, :start_at),
      end: Map.get(event, :end_at),
      recurrence_rule: Map.get(event, :recurrence_rule)
    }

  defp recurring?(event), do: Map.get(event, :recurrence_rule) not in [nil, ""]

  defp later_end(_current, nil), do: nil
  defp later_end(nil, new), do: new

  defp later_end(current, new),
    do: if(DateTime.compare(new, current) == :gt, do: new, else: current)

  defp maybe_move_lobby(%{starts_at: same}, %{starts_at: same}), do: :ok
  defp maybe_move_lobby(_room, %{starts_at: nil}), do: :ok
  defp maybe_move_lobby(_room, updated), do: enqueue(updated, "update")

  defp enqueue(room, action) do
    case VideoSyncWorker.enqueue_event_room(room.id, action) do
      {:ok, _status} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue video room sync for a calendar event",
          calendar_event_video_room_id: room.id,
          action: action,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp series_end(rule, %{start: start, end: finish}) do
    with true <- bounded_rule?(rule),
         %DateTime{} = start_dt <- to_datetime(start),
         %DateTime{} = end_dt <- to_datetime(finish),
         {:ok, parsed} <- RecurrenceExpander.parse_rrule(rule),
         %DateTime{} = last_start <- last_start_bound(parsed, start_dt) do
      duration = max(DateTime.diff(end_dt, start_dt, :second), 0)

      last_start
      |> DateTime.add(duration + @seconds_per_day, :second)
      |> truncate()
    else
      _unbounded -> nil
    end
  end

  defp bounded_rule?(rule) do
    rule
    |> String.replace_prefix("RRULE:", "")
    |> String.split(";", trim: true)
    |> Enum.all?(fn part ->
      [key | _value] = String.split(part, "=", parts: 2)
      String.upcase(key) in @bounded_rule_parts
    end)
  end

  # No occurrence can start after UNTIL, nor after COUNT repetitions of the
  # longest span one repetition can take. A weekday filter can push matching
  # days up to a week further apart per repetition.
  defp last_start_bound(%{until: %DateTime{} = until}, _start), do: until

  defp last_start_bound(%{count: count, freq: freq, interval: interval} = rule, start)
       when is_integer(count) and count > 0 do
    weekday_days = if rule.by_day, do: 7 * interval, else: 0
    days = count * (Map.fetch!(@period_days, freq) * interval + weekday_days)
    DateTime.add(start, days * @seconds_per_day, :second)
  end

  defp last_start_bound(_rule, _start), do: nil

  defp to_datetime(%DateTime{} = datetime), do: datetime
  defp to_datetime(%Date{} = date), do: midnight(date)
  defp to_datetime(_other), do: nil

  defp midnight(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp truncate(datetime),
    do: datetime |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)
end
