defmodule Tymeslot.Integrations.Calendar.Google.SeriesPatch do
  @moduledoc """
  The `PATCH` body that edits every occurrence of a Google recurring event
  through its master, from the edit of one occurrence. Pure data: the
  provider reads the master, and writes what this builds.

  A body carries only what the edit changes, because `events.update` is a
  full replace that would take the master's recurrence, reminders, colour
  and `timeZone` with anything it left out:

    * **Plain fields** (`:summary`, `:description`, `:location`, `:colour`,
      `:reminders`, `:attendees`) are sent under their Google keys, mapped
      as `Google.EventMapper` maps them. A field the edit cleared is sent
      cleared (`colorId: null`, the calendar's default reminders, no
      attendees), which a replace would have done by leaving it out.
    * **A move** of the occurrence moves the master's `start` and `end` by
      as much, on the wall clock of the master's own `timeZone`, which
      Google requires on a recurring event and expands the series in (see
      `Recurrence.SeriesMove`). The `recurrence` lines follow it: the
      `RRULE` (and any `EXRULE`) as `ICalBuilder.Series.RuleShift` keeps a
      rule in step with a move, so a weekly Monday series moved to Tuesday
      reads `BYDAY=TU` and its `UNTIL` moves with it; and every `EXDATE`
      and `RDATE` by the same amount in the form it is written in
      (`ICalBuilder.Series.Shift`), or the dates the series excludes would
      come back. A rule that pins its occurrences
      in a way the move cannot follow refuses it
      (`{:error, :rule_pins_occurrences}`).
    * **A new rule** replaces only the `RRULE` line, its `UNTIL` refitted to
      the series' value type and zone; the exception lines stay. A rule the
      edit states is the organiser's for the moved series, so it is written
      as given rather than rotated.

  Occurrences edited on their own in Google are separate events that name
  the master; they are not moved here. Google keeps or drops them itself
  when the master changes.
  """

  alias Tymeslot.Integrations.Calendar.Google.EventMapper
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series.Document
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series.RuleShift
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series.Shift
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias Tymeslot.Integrations.Calendar.Recurrence.SeriesMove

  # The payload fields an edit of every occurrence writes as they are, and
  # the Google key each becomes.
  @field_keys %{
    summary: "summary",
    description: "description",
    location: "location",
    colour: "colorId",
    reminders: "reminders",
    attendees: "attendees"
  }

  # What a cleared field is sent as: `EventMapper` leaves it out, which on a
  # replace clears it and on a patch would leave the old value.
  @cleared %{
    "summary" => "",
    "description" => "",
    "location" => "",
    "colorId" => nil,
    "reminders" => %{"useDefault" => true},
    "attendees" => []
  }

  @doc """
  The body that applies `edit` (see `Recurrence.SeriesMove.edit/0`, with
  the payload fields it changes in `:changes`) to `master`, the series'
  master event as Google returned it. An empty map when nothing it writes
  changed.
  """
  @spec build(map(), SeriesMove.edit()) :: {:ok, map()} | {:error, term()}
  def build(master, %{changes: changes} = edit) do
    with {:ok, timing, zone} <- master_timing(master),
         {:ok, move} <- SeriesMove.move(edit, timing, zone),
         {:ok, recurrence} <- recurrence(master, move, changes, timing, zone) do
      body =
        changes
        |> fields()
        |> Map.merge(timing_body(move, zone))
        |> put_recurrence(recurrence, master["recurrence"])

      {:ok, body}
    end
  end

  defp fields(changes) do
    changed = Map.take(changes, Map.keys(@field_keys))
    formatted = EventMapper.format_event_data(changed)

    Map.new(changed, fn {field, _value} ->
      key = Map.fetch!(@field_keys, field)
      {key, Map.get(formatted, key, Map.fetch!(@cleared, key))}
    end)
  end

  # --- Timing ---

  @doc """
  The timing of `master` as Google returned it: whole days, or wall clocks
  in its `timeZone`, with that zone (`nil` for an all-day series). A timed
  master without a `timeZone` is `{:error, :unreadable_timing}`.
  """
  @spec master_timing(map()) ::
          {:ok, SeriesMove.timing(), String.t() | nil} | {:error, :unreadable_timing}
  def master_timing(%{"start" => %{"date" => start}, "end" => %{"date" => finish}}) do
    with {:ok, start} <- Date.from_iso8601(start),
         {:ok, finish} <- Date.from_iso8601(finish) do
      {:ok, {start, finish}, nil}
    else
      _unreadable -> {:error, :unreadable_timing}
    end
  end

  def master_timing(%{
        "start" => %{"dateTime" => start, "timeZone" => zone},
        "end" => %{"dateTime" => finish}
      })
      when is_binary(zone) do
    with {:ok, start} <- wall(start, zone),
         {:ok, finish} <- wall(finish, zone) do
      {:ok, {start, finish}, zone}
    end
  end

  def master_timing(_master), do: {:error, :unreadable_timing}

  defp wall(value, zone) do
    with {:ok, instant, _offset} <- DateTime.from_iso8601(value),
         {:ok, local} <- DateTime.shift_zone(instant, zone) do
      {:ok, local |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)}
    else
      _unreadable -> {:error, :unreadable_timing}
    end
  end

  defp timing_body(:unmoved, _zone), do: %{}

  defp timing_body(%{start: %Date{} = start, end: finish}, _zone),
    do: %{
      "start" => %{"date" => Date.to_iso8601(start)},
      "end" => %{"date" => Date.to_iso8601(finish)}
    }

  defp timing_body(%{start: start, end: finish}, zone),
    do: %{"start" => date_time(start, zone), "end" => date_time(finish, zone)}

  defp date_time(naive, zone),
    do: %{"dateTime" => NaiveDateTime.to_iso8601(naive), "timeZone" => zone}

  # --- Recurrence ---

  defp recurrence(master, move, changes, {start, _finish}, zone) do
    lines = master["recurrence"] || []
    shift = if move == :unmoved, do: 0, else: move.shift

    case Map.fetch(changes, :recurrence_rule) do
      {:ok, rule} ->
        with_rule(lines, rule, shift, match?(%Date{}, start), zone)

      :error ->
        days = if move == :unmoved, do: 0, else: move.days
        Document.map_ok(lines, &follow(&1, shift, days, zone: zone))
    end
  end

  defp with_rule(_lines, nil, _shift, _all_day?, _zone), do: {:error, :rule_removal}

  defp with_rule(lines, rule, shift, all_day?, zone) do
    with {:ok, rule} <- RRule.retarget(rule, all_day: all_day?, timezone: zone) do
      line = "RRULE:" <> RRule.strip_prefix(rule)
      # A stated rule is written as given, so only the exceptions move.
      Document.map_ok(lines, fn written ->
        if rule_line?(written, "RRULE"),
          do: {:ok, line},
          else: follow(written, shift, 0, zone: zone, keep_until: true)
      end)
    end
  end

  defp follow(line, shift, days, opts) do
    cond do
      rule_line?(line, "RRULE") or rule_line?(line, "EXRULE") ->
        RuleShift.follow(line, shift, days, opts)

      rule_line?(line, "EXDATE") or rule_line?(line, "RDATE") ->
        Shift.shift_line(line, shift)

      true ->
        {:ok, line}
    end
  end

  defp rule_line?(line, name) do
    upcased = String.upcase(line)
    String.starts_with?(upcased, name <> ":") or String.starts_with?(upcased, name <> ";")
  end

  # Sent only when it changed: a body that carries the master's own lines
  # back rewrites nothing, but says more than the edit did.
  defp put_recurrence(body, lines, lines), do: body
  defp put_recurrence(body, lines, nil) when lines == [], do: body
  defp put_recurrence(body, lines, _written), do: Map.put(body, "recurrence", lines)
end
