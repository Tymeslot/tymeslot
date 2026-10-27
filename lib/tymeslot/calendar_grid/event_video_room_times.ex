defmodule Tymeslot.CalendarGrid.EventVideoRoomTimes do
  @moduledoc """
  When a calendar grid event's video room opens its lobby and when the room
  stops being needed, worked out from the event's timing. Pure: no database,
  no provider.

  Every rule here errs towards keeping a room usable, because a conversation
  deleted while still in use leaves attendees with a dead join link, while one
  kept too long only lingers in the organiser's list.

  ## One-off events

  A timed event's lobby opens at its start and its room is needed until it
  ends. An all-day event has no hour to wait for: its lobby opens at the
  earliest moment its first day begins anywhere (see
  `Tymeslot.Integrations.Video.LobbyOpening`), and its room is kept for the
  whole day after its exclusive end date, which covers every timezone.

  ## Recurring series

  A series is any event carrying a recurrence rule, or an occurrence row that
  names its parent (`recurring_event_id`), as Google and Outlook cache them.

  Its room is needed until no occurrence can still be running. That is only
  known from the rule's `UNTIL`, or from its `COUNT` when every repetition is
  bounded in length. A rule whose repetitions can skip (a monthly rule from the
  29th, 30th or 31st, a yearly one from 29 February, an ordinal weekday such as
  `5FR`) or with any part the grid's recurrence editor does not write is treated
  as having no end, and so is an occurrence row with no rule.

  A `COUNT` is counted from the series' first start. A Google or Outlook
  occurrence row carries its series' rule but starts where it falls in the
  series, so the caller gives it the series' first start as `:series_start`
  (`Tymeslot.Integrations.Calendar.SeriesRules.with_series_start/1`); without
  one the event's own start is used, which can only put the end later.

  One occurrence says nothing about the whole series, so for a series a change
  only ever opens the lobby earlier and only ever moves the end later.
  """

  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias Tymeslot.Integrations.Video.LobbyOpening

  @typedoc "Whether the times follow the event exactly or only ever widen."
  @type mode :: :exact | :series

  @type times :: {mode(), DateTime.t() | nil, DateTime.t() | nil}

  @seconds_per_day 86_400

  # The most days one repetition of each frequency can span, for the rules
  # whose repetitions never skip (see `skipping_rule?/2`).
  @period_days %{daily: 1, weekly: 7, monthly: 31, yearly: 366}

  @doc """
  The times an event's timing gives its room.

  Accepts the grid's event and cache rows (`start_at`/`end_at` for a timed
  event, `start_date`/`end_date` for an all-day one) and the create form's
  payload (`start`/`end`).
  """
  @spec for_event(map()) :: times()
  def for_event(event) do
    %{all_day: all_day, start: start, end: finish} = timing(event)
    rule = blank_to_nil(Map.get(event, :recurrence_rule))

    if recurring?(event) do
      {:series, lobby(all_day, start),
       rule &&
         rule
         |> series_end(all_day, {start, finish}, series_start(event), series_zone(event, all_day))
         |> later_than_own(one_off_end(all_day, finish))}
    else
      {:exact, lobby(all_day, start), one_off_end(all_day, finish)}
    end
  end

  @doc """
  Whether an event row is one of a recurring series.
  """
  @spec recurring?(map()) :: boolean()
  def recurring?(event),
    do:
      blank_to_nil(Map.get(event, :recurrence_rule)) != nil or
        blank_to_nil(Map.get(event, :recurring_event_id)) != nil

  @doc """
  The lobby time and end a room records when it is first made.
  """
  @spec initial(times()) :: {DateTime.t() | nil, DateTime.t() | nil}
  def initial({_mode, lobby, ends}), do: {lobby, ends}

  @doc """
  The lobby time and end a room with `current` values takes after its event
  changed to `times`.
  """
  @spec merge({DateTime.t() | nil, DateTime.t() | nil}, times()) ::
          {DateTime.t() | nil, DateTime.t() | nil}
  def merge({current_lobby, _current_ends}, {:exact, lobby, ends}),
    do: {lobby || current_lobby, ends}

  def merge({current_lobby, current_ends}, {:series, lobby, ends}),
    do: {earlier_lobby(current_lobby, lobby), later_end(current_ends, ends)}

  @doc """
  The later of two ends, where nil is no known end and so later than any.
  """
  @spec later_end(DateTime.t() | nil, DateTime.t() | nil) :: DateTime.t() | nil
  def later_end(nil, _new), do: nil
  def later_end(_current, nil), do: nil
  def later_end(current, new), do: if(DateTime.after?(new, current), do: new, else: current)

  # An open lobby stays open: nothing records when a series first began.
  defp earlier_lobby(nil, _new), do: nil
  defp earlier_lobby(current, nil), do: current
  defp earlier_lobby(current, new), do: if(DateTime.before?(new, current), do: new, else: current)

  defp timing(%{start: start} = event),
    do: %{all_day: Map.get(event, :all_day, false) == true, start: start, end: event[:end]}

  defp timing(%{all_day: true} = event),
    do: %{all_day: true, start: Map.get(event, :start_date), end: Map.get(event, :end_date)}

  defp timing(event),
    do: %{all_day: false, start: Map.get(event, :start_at), end: Map.get(event, :end_at)}

  defp lobby(true, %Date{} = start_date), do: LobbyOpening.opens_at(start_date)
  defp lobby(false, %DateTime{} = start), do: LobbyOpening.opens_at(start)
  defp lobby(_all_day, _start), do: nil

  defp one_off_end(true, %Date{} = end_date),
    do: end_date |> midnight() |> DateTime.add(@seconds_per_day, :second)

  defp one_off_end(false, %DateTime{} = finish), do: truncate(finish)
  defp one_off_end(_all_day, _finish), do: nil

  defp series_end(rule, all_day, {start, finish}, series_start, zone) do
    with {:ok, parsed} <- RRule.parse(rule),
         true <- bounded_rule?(parsed),
         %DateTime{} = start_dt <- to_datetime(start),
         %DateTime{} = end_dt <- to_datetime(finish),
         first_dt = to_datetime(series_start) || start_dt,
         %DateTime{} = last_start <- last_start_bound(parsed, first_dt, all_day, zone) do
      duration = max(DateTime.diff(end_dt, start_dt, :second), 0)

      last_start
      |> DateTime.add(duration + @seconds_per_day, :second)
      |> truncate()
    else
      _unbounded -> nil
    end
  end

  # Only the parts the grid's recurrence editor writes bound the last start
  # below; anything else could put an occurrence later than they allow.
  defp bounded_rule?(%RRule{other: [], by_month_day: nil, by_month: nil, by_set_pos: nil}),
    do: true

  defp bounded_rule?(%RRule{}), do: false

  # No occurrence can start after UNTIL, nor after COUNT repetitions of the
  # longest span one repetition can take. A weekday filter can push matching
  # days up to a week further apart per repetition.
  defp last_start_bound(%RRule{until: until} = parsed, _start, _all_day, zone)
       when is_binary(until),
       do: RRule.until_instant(parsed, zone)

  defp last_start_bound(
         %RRule{count: count, freq: freq, interval: interval} = parsed,
         start,
         all_day,
         _zone
       )
       when is_integer(count) and count > 0 do
    if skipping_rule?(parsed, start, all_day) do
      nil
    else
      weekday_days = if parsed.by_day, do: 7 * interval, else: 0
      days = count * (Map.fetch!(@period_days, freq) * interval + weekday_days)
      DateTime.add(start, days * @seconds_per_day, :second)
    end
  end

  defp last_start_bound(_parsed, _start, _all_day, _zone), do: nil

  # RFC 5545 skips a repetition that falls on a date the month or year does
  # not have, so COUNT repetitions can then span far more than COUNT periods.
  # A timed start is judged in UTC, which can be a day either side of the
  # event's own day, so the day before each boundary counts too.
  defp skipping_rule?(parsed, start, all_day) do
    ordinal_weekday?(parsed) or skipping_start?(parsed.freq, start, all_day)
  end

  defp ordinal_weekday?(%RRule{by_day: by_day}),
    do: Enum.any?(by_day || [], fn {ordinal, _weekday} -> ordinal != nil end)

  defp skipping_start?(:monthly, start, all_day), do: start.day >= day_limit(28, all_day)

  defp skipping_start?(:yearly, start, all_day) do
    {month, day} = {start.month, start.day}
    (month == 2 and day >= day_limit(28, all_day)) or (month == 3 and day == 1 and not all_day)
  end

  defp skipping_start?(_freq, _start, _all_day), do: false

  defp day_limit(day, true), do: day + 1
  defp day_limit(day, false), do: day

  defp series_start(event), do: Map.get(event, :series_start)

  # An occurrence moved on its own can end after the last start its series'
  # rule allows, and its room is still needed until it ends. Nil (no known
  # end) stays nil.
  defp later_than_own(nil, _own_end), do: nil
  defp later_than_own(rule_end, nil), do: rule_end
  defp later_than_own(rule_end, own_end), do: later_end(rule_end, own_end)

  # The zone the series' UNTIL is read in, as the expander reads it: the
  # event's own for a timed series, UTC (the zone an all-day series is
  # stepped in) for an all-day one or a row without a known zone.
  defp series_zone(_event, true = _all_day), do: "Etc/UTC"

  defp series_zone(event, _all_day) do
    zone = Map.get(event, :timezone)

    if is_binary(zone) and match?({:ok, _now}, DateTime.now(zone)), do: zone, else: "Etc/UTC"
  end

  defp to_datetime(%DateTime{} = datetime), do: datetime
  defp to_datetime(%Date{} = date), do: midnight(date)
  defp to_datetime(_other), do: nil

  defp midnight(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp truncate(datetime),
    do: datetime |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(value), do: value
end
