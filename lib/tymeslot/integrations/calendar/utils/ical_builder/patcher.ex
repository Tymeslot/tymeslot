defmodule Tymeslot.Integrations.Calendar.ICalBuilder.Patcher do
  @moduledoc """
  Property-level patching of a stored iCalendar document.

  `ICalBuilder.build_simple_event/2` serialises the whole event from
  Tymeslot's payload, which is right for an event Tymeslot authored and wrong
  for one it merely synced: everything the payload does not model (`ATTENDEE`
  and its `PARTSTAT`/`ROLE`/`RSVP` parameters, `CATEGORIES`, `SEQUENCE`,
  `X-` properties, an `ORGANIZER` the server set) disappears from the
  organiser's calendar the moment the event is edited.

  This module rewrites only the properties the payload carries, in place, and
  leaves every other line of the document exactly as the server returned it.

  ## What is patched

  Each payload key owns one property (`:summary` → `SUMMARY`, `:start_time` →
  `DTSTART`, ...). A key the payload does not carry leaves its property alone;
  a key it carries with an empty value deletes the property, so clearing a
  field in the grid clears it on the server too. Reminders are the one
  subcomponent: supplying `:reminders` replaces the event's `VALARM` blocks,
  omitting the key keeps them.

  ## What is left alone

    * Components other than `VEVENT`. A `VTIMEZONE` carries its own `DTSTART`
      and `RRULE` for each `STANDARD`/`DAYLIGHT` subcomponent; patching those
      would corrupt the timezone definition.
    * `VEVENT`s carrying a `RECURRENCE-ID`. Those are overrides of single
      occurrences with their own timing; only the master event of the series
      is patched.
    * Attendees, unless the document has none. `ATTENDEE` is deliberately
      never emitted (see `Properties.build_attendee_lines/1`: a CalDAV server
      that runs iTIP scheduling would email every attendee a second
      invitation), so an event that already advertises attendees keeps the
      block the server gave it, untouched. An event with no `ATTENDEE` block
      is one Tymeslot wrote, and its `CONTACT` lines are rewritten from the
      payload as usual.
  """

  alias Tymeslot.Integrations.Calendar.ICalBuilder.Alarms
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Format
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Properties

  @doc """
  Applies the property changes `event_data` describes to `raw_ical`.

  Returns the patched document, folded per RFC 5545 §3.1. A document with no
  `VEVENT` comes back unchanged; callers that need a document in that case
  build one with `ICalBuilder.build_simple_event/2` instead.
  """
  @spec patch(String.t(), map()) :: String.t()
  def patch(raw_ical, event_data) when is_binary(raw_ical) and is_map(event_data) do
    patch_set = build_patch_set(event_data)

    raw_ical
    |> LineFolder.unfold_lines()
    |> Enum.reject(&(&1 == ""))
    |> patch_components(patch_set)
    |> Enum.join("\r\n")
    |> Kernel.<>("\r\n")
    |> LineFolder.fold_lines()
  end

  # A patch set is the list of {properties it replaces, replacement lines} the
  # payload asks for, plus the reminders decision, computed once for the whole
  # document.
  defp build_patch_set(event_data) do
    entries =
      Enum.reject(
        [
          {["DTSTAMP"], "DTSTAMP:#{Format.format_datetime(DateTime.utc_now())}"},
          timing_entry(event_data, :start_time, ["DTSTART"], &Properties.build_dtstart/1),
          # RFC 5545 §3.6.1 allows DTEND or DURATION, never both, so a stored
          # DURATION has to go when DTEND arrives.
          timing_entry(event_data, :end_time, ["DTEND", "DURATION"], &Properties.build_dtend/1),
          text_entry(event_data, :summary, "SUMMARY"),
          text_entry(event_data, :description, "DESCRIPTION"),
          text_entry(event_data, :location, "LOCATION"),
          entry(event_data, :colour, ["COLOR"], &Properties.build_colour_line/1),
          entry(event_data, :recurrence_rule, ["RRULE"], &Properties.build_rrule_line/1),
          entry(event_data, :recurrence_exceptions, ["EXDATE"], &Properties.build_exdate/1),
          entry(event_data, :transparency, ["TRANSP"], &Properties.build_transp/1),
          entry(event_data, :status, ["STATUS"], &Properties.build_status/1),
          entry(event_data, :visibility, ["CLASS"], &Properties.build_class/1),
          entry(event_data, :conference_url, ["CONFERENCE"], &Properties.build_conference_line/1)
        ],
        &is_nil/1
      )

    %{entries: entries, event_data: event_data}
  end

  defp entry(event_data, key, properties, builder) do
    if Map.has_key?(event_data, key), do: {properties, builder.(event_data)}
  end

  # DTSTART and DTEND are the two properties a VEVENT cannot do without, so a
  # payload that carries the key with no value leaves the stored timing alone
  # rather than deleting it.
  defp timing_entry(event_data, key, properties, builder) do
    case Map.get(event_data, key) do
      nil -> nil
      _value -> {properties, builder.(event_data)}
    end
  end

  defp text_entry(event_data, key, property) do
    case Map.fetch(event_data, key) do
      {:ok, value} -> {[property], "#{property}:#{Format.escape_text(value || "")}"}
      :error -> nil
    end
  end

  defp patch_components([], _patch_set), do: []

  defp patch_components(["BEGIN:VEVENT" | rest], patch_set) do
    {body, remaining} = take_until(rest, "END:VEVENT", [])

    ["BEGIN:VEVENT"] ++
      patch_vevent(body, patch_set) ++
      ["END:VEVENT"] ++ patch_components(remaining, patch_set)
  end

  defp patch_components([line | rest], patch_set),
    do: [line | patch_components(rest, patch_set)]

  defp take_until([], _terminator, acc), do: {Enum.reverse(acc), []}
  defp take_until([terminator | rest], terminator, acc), do: {Enum.reverse(acc), rest}
  defp take_until([line | rest], terminator, acc), do: take_until(rest, terminator, [line | acc])

  defp patch_vevent(body, patch_set) do
    {properties, alarms} = split_alarms(body, [], [])

    if override?(properties) do
      body
    else
      entries = patch_set.entries ++ contact_entries(properties, patch_set.event_data)
      replaced = MapSet.new(Enum.flat_map(entries, fn {names, _lines} -> names end))

      kept = Enum.reject(properties, &MapSet.member?(replaced, property_name(&1)))
      added = Enum.flat_map(entries, fn {_names, lines} -> content_lines(lines) end)

      kept ++ added ++ patched_alarms(alarms, patch_set.event_data)
    end
  end

  # An occurrence override carries the timing of its own instance; the payload
  # describes the series' master event, so applying it here would move every
  # exception onto the master's start.
  defp override?(properties), do: Enum.any?(properties, &(property_name(&1) == "RECURRENCE-ID"))

  defp contact_entries(properties, event_data) do
    if Map.has_key?(event_data, :attendees) and not advertises_attendees?(properties) do
      [{["CONTACT"], Properties.build_attendee_lines(event_data)}]
    else
      []
    end
  end

  defp advertises_attendees?(properties),
    do: Enum.any?(properties, &(property_name(&1) == "ATTENDEE"))

  defp patched_alarms(alarms, event_data) do
    if Map.has_key?(event_data, :reminders) do
      event_data |> Alarms.build_reminders() |> content_lines()
    else
      Enum.concat(alarms)
    end
  end

  # VALARM is the only subcomponent a VEVENT may contain. Its own DESCRIPTION,
  # SUMMARY and DURATION lines must never be read as the event's, so the blocks
  # are lifted out before any property is matched.
  defp split_alarms([], properties, alarms),
    do: {Enum.reverse(properties), Enum.reverse(alarms)}

  defp split_alarms(["BEGIN:VALARM" | rest], properties, alarms) do
    {body, remaining} = take_until(rest, "END:VALARM", [])
    alarm = ["BEGIN:VALARM"] ++ body ++ ["END:VALARM"]
    split_alarms(remaining, properties, [alarm | alarms])
  end

  defp split_alarms([line | rest], properties, alarms),
    do: split_alarms(rest, [line | properties], alarms)

  # A serialiser may answer with several lines (attendees, alarms) or with
  # nothing at all, and Alarms uses bare newlines, so every replacement is
  # normalised to a list of content lines here.
  defp content_lines(nil), do: []
  defp content_lines(lines), do: String.split(lines, ~r/\r\n|\r|\n/, trim: true)

  # RFC 5545 §3.1: the property name runs to the first parameter separator or
  # the value separator, whichever comes first.
  defp property_name(line) do
    line
    |> String.split([";", ":"], parts: 2)
    |> hd()
    |> String.upcase()
  end
end
