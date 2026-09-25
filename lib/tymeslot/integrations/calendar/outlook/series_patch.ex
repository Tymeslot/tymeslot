defmodule Tymeslot.Integrations.Calendar.Outlook.SeriesPatch do
  @moduledoc """
  The `PATCH` body that edits every occurrence of an Outlook recurring event
  through its series master, from the edit of one occurrence. Pure data: the
  provider reads the master, and writes what this builds.

  Graph merges a `PATCH` into the event, so a body carries only what the
  edit changes. `Outlook.EventMapper.format_event_data/1` is not used for the
  body as a whole: it sends every field, and the timing converted from the
  occurrence rather than the master.

    * **Plain fields** (`:summary`, `:description`, `:location`,
      `:reminders`, `:attendees`) are sent under their Graph keys, mapped as
      `EventMapper` maps them. Outlook events carry no colour Tymeslot
      writes, so `:colour` is not sent.
    * **A move** of the occurrence moves the master's `start` and `end` by
      as much, on the wall clock of the zone the series was created in
      (`originalStartTimeZone`, which is also the label they are written
      with; see `Recurrence.SeriesMove`). The master is read in UTC (the
      client asks Graph for UTC), so a series in a zone Tymeslot cannot
      read refuses a move (`{:error, :unreadable_timing}`) rather than be
      moved to UTC.
    * When the move changes the master's date, the `recurrence` follows it:
      Graph requires the range's `startDate` to be the date of `start`, and
      the pattern is turned as `ICalBuilder.Series.RuleShift` turns an
      RRULE (a weekly Monday series moved to Tuesday repeats on Tuesday; an
      absolute monthly one moves to the new day of the month). The pattern's
      other keys, `firstDayOfWeek` included, and the range's end are kept.
      A relative pattern (the second Monday of the month) cannot follow a
      move to another date and refuses it
      (`{:error, :rule_pins_occurrences}`).
    * **A new rule** is sent as the whole `recurrence`: the pattern the
      rule describes, and its range when it states an end; a rule that
      states none keeps the master's range, from the master's start date.

  Occurrences edited on their own (exceptions) are not moved here; Graph
  keeps or drops them itself when the master changes.
  """

  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series.RuleShift
  alias Tymeslot.Integrations.Calendar.Outlook.EventMapper
  alias Tymeslot.Integrations.Calendar.Outlook.RecurrenceConverter
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias Tymeslot.Integrations.Calendar.Recurrence.SeriesMove
  alias Tymeslot.Timezones
  alias Tymeslot.Utils.DateTimeUtils

  # The payload fields an edit of every occurrence writes as they are, and
  # the Graph keys each becomes.
  @field_keys %{
    summary: ["subject"],
    description: ["body"],
    location: ["location"],
    reminders: ["isReminderOn", "reminderMinutesBeforeStart"],
    attendees: ["attendees"]
  }

  # `EventMapper` drops an empty subject, which a patch has to send to clear.
  @cleared %{"subject" => ""}

  @graph_weekdays ~w(monday tuesday wednesday thursday friday saturday sunday)
  @rrule_weekdays ~w(MO TU WE TH FR SA SU)

  @doc """
  The body that applies `edit` (see `Recurrence.SeriesMove.edit/0`, with
  the payload fields it changes in `:changes`) to `master`, the series
  master as Graph returned it (in UTC). An empty map when nothing it writes
  changed.
  """
  @spec build(map(), SeriesMove.edit()) :: {:ok, map()} | {:error, term()}
  def build(master, %{changes: changes} = edit) do
    with {:ok, timing, zone} <- master_timing(master),
         {:ok, move} <- SeriesMove.move(edit, timing, elem(zone, 0)),
         {:ok, recurrence} <- recurrence(master, move, changes, timing, elem(zone, 0)) do
      body =
        changes
        |> fields()
        |> Map.merge(timing_body(move, zone))
        |> put_recurrence(recurrence)

      {:ok, body}
    end
  end

  defp fields(changes) do
    changed = Map.take(changes, Map.keys(@field_keys))
    formatted = EventMapper.format_event_data(changed)

    changed
    |> Enum.flat_map(fn {field, _value} -> Map.fetch!(@field_keys, field) end)
    |> Enum.flat_map(fn key ->
      case Map.fetch(formatted, key) do
        {:ok, value} -> [{key, value}]
        :error -> Enum.to_list(Map.take(@cleared, [key]))
      end
    end)
    |> Map.new()
  end

  # --- Timing ---

  @doc """
  The timing of `master` as Graph returned it, on the series' own wall
  clock: whole days, or wall clocks in the zone the series was created in.
  Comes with `{zone, label}`: that zone as an IANA name (`nil` when it cannot
  be read, and the timing is then read in UTC) and the label its timing is
  written back with.
  """
  @spec master_timing(map()) ::
          {:ok, SeriesMove.timing(), {String.t() | nil, String.t() | nil}}
          | {:error, :unreadable_timing}
  def master_timing(%{"isAllDay" => true, "start" => start, "end" => finish}) do
    with {:ok, start_date} <- date(start),
         {:ok, end_date} <- date(finish) do
      {:ok, {start_date, end_date}, {nil, Map.get(start, "timeZone") || "UTC"}}
    end
  end

  def master_timing(%{"start" => %{"dateTime" => _start} = start, "end" => finish} = master) do
    label = master["originalStartTimeZone"]
    zone = known_zone(label)

    with {:ok, start_wall} <- wall(start, zone),
         {:ok, end_wall} <- wall(finish, zone) do
      {:ok, {start_wall, end_wall}, {zone, label}}
    end
  end

  def master_timing(_master), do: {:error, :unreadable_timing}

  # `Timezones.sanitize/1` maps Graph's Windows names to IANA ones, and hands
  # back what it does not recognise as it was.
  defp known_zone(label) do
    with zone when is_binary(zone) <- Timezones.sanitize(label),
         {:ok, _now} <- DateTime.shift_zone(DateTime.utc_now(), zone) do
      zone
    else
      _unknown -> nil
    end
  end

  defp date(%{"dateTime" => value}) when is_binary(value) do
    case Date.from_iso8601(String.slice(value, 0, 10)) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :unreadable_timing}
    end
  end

  defp date(_value), do: {:error, :unreadable_timing}

  # A value as Graph returned it (a wall clock in its `timeZone`) on the
  # series' own wall clock; UTC when the series' zone is unreadable, which
  # only an edit that leaves the timing alone may go on with.
  defp wall(%{"dateTime" => value} = timing, zone) when is_binary(value) do
    own_zone = known_zone(Map.get(timing, "timeZone")) || "Etc/UTC"

    with {:ok, naive} <- NaiveDateTime.from_iso8601(value),
         {:ok, instant} <-
           DateTimeUtils.resolve_local(
             NaiveDateTime.to_date(naive),
             NaiveDateTime.to_time(naive),
             own_zone
           ),
         {:ok, local} <- DateTime.shift_zone(instant, zone || "Etc/UTC") do
      {:ok, local |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)}
    else
      _unreadable -> {:error, :unreadable_timing}
    end
  end

  defp wall(_timing, _zone), do: {:error, :unreadable_timing}

  defp timing_body(:unmoved, _zone), do: %{}

  defp timing_body(%{start: %Date{} = start, end: finish}, {_zone, label}),
    do: %{"start" => midnight(start, label), "end" => midnight(finish, label)}

  defp timing_body(%{start: start, end: finish}, {_zone, label}),
    do: %{"start" => date_time(start, label), "end" => date_time(finish, label)}

  defp midnight(date, label),
    do: %{"dateTime" => Date.to_iso8601(date) <> "T00:00:00", "timeZone" => label}

  defp date_time(naive, label),
    do: %{"dateTime" => NaiveDateTime.to_iso8601(naive), "timeZone" => label}

  # --- Recurrence ---

  defp recurrence(master, move, changes, {start, _finish}, zone) do
    start_date = date_of(if move == :unmoved, do: start, else: move.start)

    case Map.fetch(changes, :recurrence_rule) do
      {:ok, rule} -> with_rule(master["recurrence"], rule, start_date, zone)
      :error -> follow(master["recurrence"], move, start_date, zone)
    end
  end

  defp with_rule(_recurrence, nil, _start_date, _zone), do: {:error, :rule_removal}

  defp with_rule(recurrence, rule, start_date, zone) do
    case RecurrenceConverter.rrule_to_outlook(rule, start_date, zone) do
      nil -> {:error, :unsupported_rule}
      built -> {:ok, %{built | "range" => range(built, recurrence, rule, start_date, zone)}}
    end
  end

  defp range(built, recurrence, rule, start_date, zone) do
    parsed = RRule.parse(rule, timezone: zone)

    case recurrence do
      %{"range" => %{} = master_range}
      when not is_map_key(parsed, :count) and not is_map_key(parsed, :until) ->
        Map.put(master_range, "startDate", Date.to_iso8601(start_date))

      _stated_or_none ->
        built["range"]
    end
  end

  defp follow(_recurrence, :unmoved, _start_date, _zone), do: {:ok, nil}
  defp follow(_recurrence, %{days: 0}, _start_date, _zone), do: {:ok, nil}

  defp follow(%{"pattern" => pattern, "range" => range}, move, start_date, zone) do
    with {:ok, rule} <- pattern_rule(pattern, range),
         {:ok, "RRULE:" <> turned} <- RuleShift.follow("RRULE:" <> rule, move.shift, move.days),
         %{"pattern" => turned_pattern} <-
           RecurrenceConverter.rrule_to_outlook(turned, start_date, zone) do
      {:ok,
       %{
         "pattern" => Map.merge(pattern, turned_pattern),
         "range" => Map.put(range, "startDate", Date.to_iso8601(start_date))
       }}
    else
      {:error, _reason} = error -> error
      _unreadable -> {:error, :rule_pins_occurrences}
    end
  end

  defp follow(_recurrence, _move, _start_date, _zone), do: {:error, :unreadable_rule}

  @doc """
  The pattern and range of a Graph `recurrence` as an RRULE, with the week
  start Graph counts an every-other-week pattern from (Sunday unless
  stated), so that a turn or a count that would cross it can be refused. A
  relative pattern (the second Monday of the month) has no RRULE form here
  and pins its occurrences (`{:error, :rule_pins_occurrences}`).
  """
  @spec pattern_rule(map(), map()) :: {:ok, String.t()} | {:error, :rule_pins_occurrences}
  def pattern_rule(pattern, range) do
    case RecurrenceConverter.outlook_to_rrule(%{"pattern" => pattern, "range" => range}) do
      nil -> {:error, :rule_pins_occurrences}
      rule -> {:ok, RRule.strip_prefix(rule) <> ";WKST=" <> week_start(pattern)}
    end
  end

  defp week_start(pattern) do
    day = String.downcase(Map.get(pattern, "firstDayOfWeek") || "sunday")
    index = Enum.find_index(@graph_weekdays, &(&1 == day)) || 6
    Enum.at(@rrule_weekdays, index)
  end

  # The date a start falls on, whole day or wall clock.
  defp date_of(%{year: year, month: month, day: day}), do: Date.new!(year, month, day)

  defp put_recurrence(body, nil), do: body
  defp put_recurrence(body, recurrence), do: Map.put(body, "recurrence", recurrence)
end
