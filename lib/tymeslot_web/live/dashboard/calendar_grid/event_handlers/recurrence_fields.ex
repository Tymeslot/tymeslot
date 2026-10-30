defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.RecurrenceFields do
  @moduledoc """
  The repeat fields an event's handlers share: the zone a series repeats in
  and the start its pattern is read against, what the repeat editor keeps
  for the event open in the details, and the composition of a canonical
  RRULE from the recurrence editor's raw form fields.
  """

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.Recurrence.Pattern
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias Tymeslot.Integrations.Calendar.Recurrence.Series
  alias Tymeslot.Timezones
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared

  @weekday_atoms %{
    "mo" => :mo,
    "tu" => :tu,
    "we" => :we,
    "th" => :th,
    "fr" => :fr,
    "sa" => :sa,
    "su" => :su
  }

  # What an `on` field's kind may name (`Pattern.kind/0`).
  @on_kinds Map.merge(@weekday_atoms, %{
              "day" => :day,
              "weekday" => :weekday,
              "weekend_day" => :weekend_day
            })

  @doc """
  The timezone a recurring event's UNTIL date ends its day in, and a one-off
  given a rule is written in: the event's own, falling back to the organiser's
  profile zone for an event that carries none.

  A one-off carrying UTC falls back too. Sync stores UTC for every event
  written with UTC times, which is how Tymeslot writes its one-offs, so that
  zone records how the event was written, not the local time a series made
  from it should keep. A series carrying UTC keeps it: its writers read an
  UNTIL back as a date in the series' own zone, so ending the day anywhere
  else moves the end by a day.

  A series belongs to the calendar it sits on, not to whoever is looking at it,
  so reading the organiser's zone for both is only right while they agree. An
  organiser in `Europe/Tallinn` ending an `America/Los_Angeles` series on 31
  December otherwise gets an UNTIL at 13:59 Los Angeles time, cutting that day's
  afternoon occurrences; west-to-east the mirror case adds one.

  Creates pass the organiser's zone directly and do not call this: an event
  being drawn on the grid has no zone of its own yet, and the grid's wall clock
  is the organiser's.
  """
  @spec recurrence_timezone(map() | nil, String.t() | nil) :: String.t() | nil
  def recurrence_timezone(event, user_timezone)
  def recurrence_timezone(nil, user_timezone), do: user_timezone

  def recurrence_timezone(event, user_timezone) do
    zone = Map.get(event, :timezone)

    cond do
      # A name the time-zone database does not know (Outlook's "Customized
      # Time Zone", say) cannot place a date anywhere.
      not Timezones.valid?(zone) -> user_timezone
      one_off?(event) and Calendar.utc_zone?(zone) -> user_timezone
      true -> zone
    end
  end

  @doc """
  The start a repeat pattern of `event` is read against
  (`Tymeslot.Integrations.Calendar.Recurrence.Pattern`): the day of an
  all-day event, else its start on the wall clock of the zone the series
  repeats in (`recurrence_timezone/2`).
  """
  @spec recurrence_start(map(), String.t()) :: Date.t() | DateTime.t()
  def recurrence_start(%{all_day: true, start_date: %Date{} = date}, _user_timezone), do: date

  def recurrence_start(event, user_timezone) do
    zone = recurrence_timezone(event, user_timezone)

    case event do
      %{start_at: %DateTime{} = start_at} -> DateTime.shift_zone!(start_at, zone)
      _no_start -> DateTime.now!(zone)
    end
  end

  @doc """
  What the repeat editor keeps for the event open in the details: the first
  start of its series (`CalendarGrid.series_start/1`), read once when the
  event is opened, and the pattern staged in the editor and not yet saved
  (`:draft`, `%{params: fields, rule: rule}`, or `nil`).

  Answers `nil` for an event whose calendar takes no repeat rule.
  """
  @spec recurrence_edit(map() | nil) :: map() | nil
  def recurrence_edit(%{id: id} = event) do
    if CalendarGrid.repeatable_provider?(Map.get(event, :provider)),
      do: %{event_id: id, series_start: CalendarGrid.series_start(event), draft: nil}
  end

  def recurrence_edit(_no_event), do: nil

  @doc """
  The start a repeat pattern of `event` is shown and built against: the
  first start of its series (see `recurrence_edit/1`), on the wall clock of
  the zone it repeats in, which is what a rule written to the whole series
  is read from. The second element says whether that start is known: a
  series whose first start was never read falls back to the event's own
  start, which only an edit of this and the following events is written
  against.
  """
  @spec series_anchor(map(), map() | nil, String.t()) :: {Date.t() | DateTime.t(), boolean()}
  def series_anchor(event, edit, user_timezone) do
    cond do
      # An event of no series begins where it starts now, whatever it was
      # opened at.
      not Series.member?(event) ->
        {recurrence_start(event, user_timezone), true}

      match?(%{event_id: id, series_start: %{}} when id == event.id, edit) ->
        {in_recurrence_zone(edit.series_start, event, user_timezone), true}

      true ->
        {recurrence_start(event, user_timezone), false}
    end
  end

  @doc """
  `start`, a `Date` or an instant, as a repeat pattern of `event` is built
  from it: a day, or a wall clock in the zone the series repeats in.
  """
  @spec in_recurrence_zone(Date.t() | DateTime.t(), map(), String.t()) :: Date.t() | DateTime.t()
  def in_recurrence_zone(%Date{} = date, _event, _user_timezone), do: date

  def in_recurrence_zone(%DateTime{} = at, event, user_timezone),
    do: DateTime.shift_zone!(at, recurrence_timezone(event, user_timezone))

  @doc "The pattern staged in the repeat editor for `event`, or `nil` (see `recurrence_edit/1`)."
  @spec recurrence_draft(map(), map() | nil) :: %{params: map(), rule: String.t() | nil} | nil
  def recurrence_draft(%{id: id}, %{event_id: id, draft: draft}), do: draft
  def recurrence_draft(_event, _edit), do: nil

  @doc """
  The zone an event's days are read in when it is toggled to or from all-day:
  for a series, the zone it repeats in (`recurrence_timezone/2`), so its
  first occurrence keeps its calendar's day; for a one-off, the viewer's, so
  it lands on the day the grid showed it on.
  """
  @spec all_day_timezone(map(), String.t() | nil) :: String.t() | nil
  def all_day_timezone(event, user_timezone) do
    if one_off?(event),
      do: user_timezone,
      else: recurrence_timezone(event, user_timezone)
  end

  # A Google or Outlook occurrence carries no rule, only the master it
  # belongs to.
  defp one_off?(event), do: not Series.member?(event)

  @doc """
  Composes a canonical RRULE string from the recurrence editor's raw form
  fields (`freq`, `interval`, `by_day[]`, `on`, `end_type`, `count`, `until`).

  Returns `nil` when no frequency is chosen ("Does not repeat") or the fields do
  not describe a valid rule. Unrecognised frequencies and malformed end
  conditions degrade gracefully — a bad `count` simply yields a never-ending
  rule rather than failing.

  The optional `event_context` map may include:
    - `:start_date` — a `Date.t()` used to reject an `until` that precedes the
      event start (which would produce a dead rule with zero occurrences).
    - `:all_day` — a boolean that controls UNTIL value-type: all-day recurring
      events must emit `UNTIL=YYYYMMDD` (RFC 5545 §3.3.10) rather than the
      default UTC date-time form.
    - `:timezone` — the timezone whose day the UNTIL date ends, from
      `recurrence_timezone/2`. A timed event's UNTIL is an instant, so the date
      the form supplies has to end its day in a zone rather than in UTC, or the
      series ends a day early west of UTC and a day late east of it.
    - `:rule` — the rule being edited, if any. Its `WKST` is kept.
    - `:check_until` — `false` to leave an `until` before `:start_date` for
      the caller to refuse later; default `true`.

  With a `:start_date` the rule is one of the editor's patterns
  (`Pattern.build/3`), anchored to that date: a weekly rule includes its
  weekday, and `on` (`day`, or `ordinal:kind` such as `2:tu`) is taken only
  when the date is that day (`Pattern.choices/1`), otherwise the start's day.

  Returns `{:error, :until_before_start}` when `until` precedes `:start_date`.
  """
  @spec compose_recurrence_rule(map(), map()) :: String.t() | nil | {:error, :until_before_start}
  def compose_recurrence_rule(params, event_context \\ %{}) do
    case parse_freq(params["freq"]) do
      nil ->
        nil

      freq ->
        start_date = Map.get(event_context, :start_date)

        opts =
          %{freq: freq}
          |> Pattern.put_interval(field_int(params["interval"]))
          |> put_by_day(freq, params["by_day"], start_date)
          |> put_start_day(freq, start_date)
          |> put_on(freq, params["on"], start_date)
          |> put_end_condition(params["end_type"], params, start_date)

        # `build/2` and `retarget/2` are handed the same value-type options, so
        # the rule composed here and the rule read back agree on how UNTIL is
        # written; retarget/2 is what rejects a series ending before it starts.
        fit_opts = [
          all_day: Map.get(event_context, :all_day, false),
          timezone: Map.get(event_context, :timezone),
          start_date: if(Map.get(event_context, :check_until, true), do: start_date)
        ]

        build_opts = [keep: Map.get(event_context, :rule)] ++ fit_opts

        rule =
          if start_date,
            do: Pattern.build(opts, start_date, build_opts),
            else: RRule.build(opts, build_opts)

        case RRule.retarget(rule, fit_opts) do
          {:ok, rule} -> rule
          {:error, :until_before_start} = error -> error
        end
    end
  end

  defp parse_freq("daily"), do: :daily
  defp parse_freq("weekly"), do: :weekly
  defp parse_freq("monthly"), do: :monthly
  defp parse_freq("yearly"), do: :yearly
  defp parse_freq(_other), do: nil

  # A number field's value, or `nil` for one empty or not a number.
  defp field_int(value) do
    case Shared.parse_int(value || "") do
      {:ok, n} -> n
      :error -> nil
    end
  end

  # "start" names the start's weekday, as the editor sends it.
  defp put_by_day(opts, :weekly, days, start_date) when is_list(days) do
    by_day =
      days
      |> Enum.map(&weekday_atom(&1, start_date))
      |> Enum.reject(&is_nil/1)

    if by_day == [], do: opts, else: Map.put(opts, :by_day, by_day)
  end

  defp put_by_day(opts, _freq, _days, _start_date), do: opts

  defp weekday_atom("start", %Date{} = start_date),
    do: Enum.at(~w(mo tu we th fr sa su)a, Date.day_of_week(start_date) - 1)

  defp weekday_atom(day, _start_date), do: Map.get(@weekday_atoms, day)

  # A weekly series repeats on its start's weekday whatever else is ticked,
  # and its days are written in the week's order. With nothing ticked the
  # rule names no day, which means that one.
  defp put_start_day(%{by_day: [_first | _rest] = days} = opts, :weekly, %Date{} = start_date) do
    weekdays = ~w(mo tu we th fr sa su)a
    start_day = Enum.at(weekdays, Date.day_of_week(start_date) - 1)
    Map.put(opts, :by_day, Enum.filter(weekdays, &(&1 in [start_day | days])))
  end

  defp put_start_day(opts, _freq, _start_date), do: opts

  # A position the start is not (it is the second Wednesday, not the first)
  # becomes the nearest one it is (`Pattern.reanchor/2`).
  defp put_on(opts, freq, value, %Date{} = start_date) when freq in [:monthly, :yearly],
    do: Map.put(opts, :on, value |> parse_on() |> Pattern.reanchor(start_date))

  defp put_on(opts, _freq, _value, _start_date), do: opts

  defp parse_on(value) when is_binary(value) do
    with [ordinal, kind] <- String.split(value, ":", parts: 2),
         {ordinal, ""} when ordinal in [1, 2, 3, 4, -1] <- Integer.parse(ordinal),
         {:ok, kind} <- Map.fetch(@on_kinds, kind) do
      {ordinal, kind}
    else
      _day_or_unknown -> :day
    end
  end

  defp parse_on(_value), do: :day

  # An end picked before its number or date is given (the field appears only
  # once the end is picked) starts from the editor's default, so the pick
  # holds rather than reading back as "Never ends" (`Pattern.put_count/2`,
  # `Pattern.put_until/3`).
  defp put_end_condition(opts, "count", params, _start_date),
    do: Pattern.put_count(opts, field_int(params["count"]))

  defp put_end_condition(opts, "until", params, start_date) do
    until =
      case Date.from_iso8601(params["until"] || "") do
        {:ok, date} -> date
        {:error, _reason} -> nil
      end

    Pattern.put_until(opts, until, start_date)
  end

  defp put_end_condition(opts, _never_or_other, _params, _start_date), do: opts
end
