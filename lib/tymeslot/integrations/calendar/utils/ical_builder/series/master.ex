defmodule Tymeslot.Integrations.Calendar.ICalBuilder.Series.Master do
  @moduledoc """
  Editing every occurrence of a recurring event stored as one CalDAV
  resource, from the edit of one of them. The public entry point, and the
  rules it follows, are `ICalBuilder.Series.edit_master/5`'s; this module is
  its implementation.
  """

  alias Tymeslot.Integrations.Calendar.CalDAV.Scheduling
  alias Tymeslot.Integrations.Calendar.ICalBuilder.ContentLines
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Patcher
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Properties
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series.Document
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series.RuleShift
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Series.Shift
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Timing
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule

  # The payload keys written here rather than by `Patcher`, which would write
  # them as a one-off event's (timing in UTC, the exceptions from the cache).
  @series_keys [:start_time, :end_time, :recurrence_rule, :recurrence_exceptions]

  # The lines that name a slot of the series or an occurrence's timing, which
  # move with the series; see `Series.Shift`.
  @moved_properties ["DTSTART", "DTEND", "RECURRENCE-ID", "EXDATE", "RDATE"]

  @doc "See `ICalBuilder.Series.edit_master/5`."
  @spec edit(String.t(), String.t(), map(), String.t() | nil, Scheduling.mode()) ::
          {:ok, String.t()} | {:error, term()}
  def edit(document, key, changes, timezone, mode) do
    components = Document.components(document)
    zones = {Document.series_zone(components, timezone), timezone}

    with {:ok, {:vevent, master}} <- find_master(components),
         reference = ContentLines.find("DTSTART", Document.properties(master)),
         :ok <- Timing.ensure_value_type(reference, changes),
         {:ok, move} <- plan_move(components, master, key, changes, zones),
         {:ok, components} <- move_series(components, move, key, zones),
         {:ok, components} <- edit_fields(components, changes, elem(zones, 0), mode),
         {:ok, components} <- follow_rule(components, reference, move.shift, zones, changes) do
      Document.serialise(components)
    end
  end

  defp find_master(components) do
    case Enum.find(components, &Document.master?/1) do
      nil -> {:error, :master_not_found}
      master -> {:ok, master}
    end
  end

  # --- How far the series moves ---

  # The shift is how far the edited occurrence moved on the series' wall
  # clock, from where it shows now (its override's DTSTART, else its slot).
  # `duration` is the one its occurrences take when the edit changed how long
  # the edited one lasts, `nil` when it did not.
  defp plan_move(components, master, key, %{start_time: start} = changes, zones)
       when is_struct(start) do
    {zone, timezone} = zones
    own = Enum.find(components, &Document.override_for?(&1, key, zone))

    with {:ok, master_duration} <- Shift.duration(Document.properties(master), zone, timezone),
         {:ok, from} <- occurrence_start(own, key, zones),
         {:ok, to} <- Shift.wall_of(start, zone),
         {:ok, current} <- occurrence_duration(own, master_duration, zones),
         {:ok, wanted} <- wanted_duration(changes, to, zone) do
      {:ok,
       %{
         shift: NaiveDateTime.diff(to, from),
         master_duration: master_duration,
         duration: if(wanted in [nil, current], do: nil, else: wanted)
       }}
    else
      :error -> {:error, :unreadable_timing}
    end
  end

  defp plan_move(_components, _master, _key, _changes, _zones),
    do: {:ok, %{shift: 0, master_duration: nil, duration: nil}}

  defp occurrence_start(nil, key, _zones), do: Shift.key_wall(key)

  defp occurrence_start({:vevent, items}, _key, {zone, timezone}) do
    case ContentLines.find("DTSTART", Document.properties(items)) do
      nil -> :error
      dtstart -> Shift.wall(dtstart, zone, timezone)
    end
  end

  defp occurrence_duration(nil, master_duration, _zones), do: {:ok, master_duration}

  defp occurrence_duration({:vevent, items}, _master_duration, {zone, timezone}),
    do: Shift.duration(Document.properties(items), zone, timezone)

  defp wanted_duration(%{end_time: finish, start_time: start}, to, zone) when is_struct(finish) do
    with {:ok, until} <- Shift.wall_of(Timing.end_boundary(finish, start), zone),
         do: {:ok, NaiveDateTime.diff(until, to)}
  end

  defp wanted_duration(_changes, _to, _zone), do: {:ok, nil}

  # --- Moving every VEVENT ---

  defp move_series(components, move, key, {zone, _timezone} = zones) do
    Document.map_ok(components, fn
      {:vevent, items} = vevent ->
        edited? = Document.override_for?(vevent, key, zone)

        with {:ok, items} <- move_items(items, move, zones, edited?),
             do: {:ok, {:vevent, items}}

      line ->
        {:ok, line}
    end)
  end

  defp move_items(items, move, zones, edited?) do
    with {:ok, resized?} <- takes_new_duration?(items, move, zones, edited?),
         {:ok, moved} <- Document.map_ok(items, &move_line(&1, move.shift)) do
      if resized?, do: put_duration(moved, move.duration), else: {:ok, moved}
    end
  end

  defp move_line(line, shift) when is_binary(line) do
    if ContentLines.property_name(line) in @moved_properties,
      do: Shift.shift_line(line, shift),
      else: {:ok, line}
  end

  defp move_line(subcomponent, _shift), do: {:ok, subcomponent}

  # The master takes the new duration, and so does every override that
  # lasted as long as it, and the edited occurrence's own whatever it lasted;
  # an override with a duration of its own keeps it.
  defp takes_new_duration?(_items, %{duration: nil}, _zones, _edited?), do: {:ok, false}
  defp takes_new_duration?(_items, _move, _zones, true = _edited?), do: {:ok, true}

  defp takes_new_duration?(items, move, {zone, timezone}, false = _edited?) do
    properties = Document.properties(items)

    if is_nil(ContentLines.find("RECURRENCE-ID", properties)) do
      {:ok, true}
    else
      case Shift.duration(properties, zone, timezone) do
        {:ok, duration} -> {:ok, duration == move.master_duration}
        :error -> {:error, :unreadable_timing}
      end
    end
  end

  # The new end is the moved start moved again by the duration, so it takes
  # DTSTART's form, and replaces a DURATION as well as a DTEND.
  defp put_duration(items, duration) do
    dtstart = ContentLines.find("DTSTART", Document.properties(items))

    with {:ok, moved} <- Shift.shift_line(dtstart, duration) do
      dtend = "DTEND" <> binary_part(moved, 7, byte_size(moved) - 7)
      {:ok, Document.replace_properties(items, ["DTEND", "DURATION"], dtend)}
    end
  end

  # --- The master's own fields ---

  defp edit_fields(components, changes, zone, mode) do
    index = Enum.find_index(components, &Document.master?/1)
    {:vevent, items} = Enum.at(components, index)

    patched =
      items
      |> Enum.flat_map(&Document.item_lines/1)
      |> Patcher.patch_vevent(Map.drop(changes, @series_keys), mode)
      |> Document.collect_items()

    with {:ok, items} <- put_rule(patched, changes, zone) do
      {:ok, List.replace_at(components, index, {:vevent, items})}
    end
  end

  defp put_rule(_items, %{recurrence_rule: nil}, _zone), do: {:error, :rule_removal}

  defp put_rule(items, %{recurrence_rule: rule}, zone) when is_binary(rule) do
    dtstart = ContentLines.find("DTSTART", Document.properties(items))

    with {:ok, rule} <- RRule.retarget(rule, all_day: Timing.date?(dtstart), timezone: zone) do
      line = Properties.build_rrule_line(%{recurrence_rule: rule})
      {:ok, Document.replace_properties(items, ["RRULE"], line)}
    end
  end

  defp put_rule(items, _changes, _zone), do: {:ok, items}

  # The rule follows the move (`Series.RuleShift`). A rule the edit itself
  # states is the organiser's for the moved series, so it is written as they
  # gave it: only a part pinning a time of day is refused.
  defp follow_rule(components, _reference, 0, _zones, _changes), do: {:ok, components}

  defp follow_rule(components, reference, shift, zones, changes) do
    index = Enum.find_index(components, &Document.master?/1)
    {:vevent, items} = Enum.at(components, index)

    with {:ok, days} <- days_moved(reference, shift, zones, changes),
         {:ok, items} <- Document.map_ok(items, &follow_line(&1, shift, days)) do
      {:ok, List.replace_at(components, index, {:vevent, items})}
    end
  end

  # How many dates the master's DTSTART moved by, on the series' wall clock.
  defp days_moved(_reference, _shift, _zones, %{recurrence_rule: _stated}), do: {:ok, 0}

  defp days_moved(reference, shift, {zone, timezone}, _changes) do
    case Shift.wall(reference, zone, timezone) do
      {:ok, from} ->
        to = NaiveDateTime.add(from, shift)
        {:ok, Date.diff(NaiveDateTime.to_date(to), NaiveDateTime.to_date(from))}

      :error ->
        {:error, :unreadable_timing}
    end
  end

  defp follow_line(line, shift, days) when is_binary(line) do
    if ContentLines.property_name(line) == "RRULE",
      do: RuleShift.follow(line, shift, days),
      else: {:ok, line}
  end

  defp follow_line(subcomponent, _shift, _days), do: {:ok, subcomponent}
end
