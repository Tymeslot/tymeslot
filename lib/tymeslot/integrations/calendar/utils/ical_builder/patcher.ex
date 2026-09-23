defmodule Tymeslot.Integrations.Calendar.ICalBuilder.Patcher do
  @moduledoc """
  Property-level patching of a stored iCalendar document.

  `ICalBuilder.build_simple_event/3` serialises the whole event from
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
    * The attendee list, unless the payload carries `:attendees`. A payload
      without the key has no opinion about who the event is with, and every
      `ATTENDEE`, `CONTACT` and `X-TYMESLOT-ATTENDEES` line stays exactly as
      the server returned it.

  ## Attendees

  A payload that carries `:attendees` states the complete new list, so a
  guest removed in the grid is removed from the document too. It is merged
  into the stored `ATTENDEE` lines rather than written over them:

    * A guest who stays keeps their stored line verbatim, `PARTSTAT`, `ROLE`,
      `RSVP`, `CN` and `SCHEDULE-AGENT` included. The cached attendee map does
      not hold those parameters for CalDAV, so rebuilding the line from it
      would reset every reply, which is how the original full rewrite lost
      them.
    * A guest who is gone loses their line. Addresses are compared without
      regard to case, as the grid compares them.
    * A guest who is new is written the way the caller's `mode` says (see
      `CalDAV.Scheduling`): `ATTENDEE;SCHEDULE-AGENT=CLIENT` in `:attendee`
      mode, so the server stores them without mailing them, since Tymeslot
      sends its own invitation.
    * An `ATTENDEE` whose address is not a `mailto:` URI (a room, a group, a
      `urn:uuid:` principal) cannot be named by the payload's list, which the
      sync builds from `mailto:` addresses only, and is kept.

  Tymeslot's own block, told apart by the `X-TYMESLOT-ATTENDEES` marker
  `build_simple_event/3` emits beside it or by the absence of any `ATTENDEE`
  at all, also has its `CONTACT` lines rewritten. In `:contact` mode such a
  block is rebuilt as `CONTACT` lines outright, so a document written under
  the other mode converges on the current one. A block the organiser's own
  client wrote keeps its `CONTACT` lines, and in `:contact` mode gains no new
  ones either: a `CONTACT` added to a document whose `CONTACT` lines this
  module does not own could never be taken away again.
  """

  alias Tymeslot.Integrations.Calendar.CalDAV.Scheduling
  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Alarms
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Format
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Properties

  @doc """
  Applies the property changes `event_data` describes to `raw_ical`.

  Returns the patched document, folded per RFC 5545 §3.1. A document with no
  `VEVENT` comes back unchanged; callers that need a document in that case
  build one with `ICalBuilder.build_simple_event/3` instead.
  """
  @spec patch(String.t(), map(), Scheduling.mode()) :: String.t()
  def patch(raw_ical, event_data, mode \\ :contact)
      when is_binary(raw_ical) and is_map(event_data) do
    patch_set = build_patch_set(event_data, mode)

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
  defp build_patch_set(event_data, mode) do
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

    %{entries: entries, event_data: event_data, mode: mode}
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
      entries = patch_set.entries ++ attendee_entries(properties, patch_set)
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

  # Both spellings are always replaced in a block of Tymeslot's own, never just
  # the one being written, so a document Tymeslot wrote under the other mode,
  # or before this project emitted `ATTENDEE` at all, converges on the current
  # one instead of carrying the attendee twice.
  @rewritten_attendee_properties ["CONTACT", "ATTENDEE", "X-TYMESLOT-ATTENDEES"]

  # The same reading of an address as `ICalParser` applies when it builds the
  # cached attendee list, so a line and the attendee the sync made of it are
  # always recognised as one and the same.
  @mailto ~r/:mailto:(.+)$/i

  defp attendee_entries(properties, %{event_data: event_data, mode: mode}) do
    case Map.fetch(event_data, :attendees) do
      {:ok, attendees} when is_list(attendees) ->
        [attendee_entry(properties, attendees, event_data, mode, ours?(properties))]

      _no_opinion ->
        []
    end
  end

  defp attendee_entry(_properties, _attendees, event_data, :contact, true = _ours),
    do: {@rewritten_attendee_properties, Properties.build_attendee_lines(event_data, :contact)}

  defp attendee_entry(properties, attendees, _event_data, mode, ours) do
    wanted = MapSet.new(attendees, &attendee_address/1)

    kept =
      Enum.filter(properties, fn line ->
        property_name(line) == "ATTENDEE" and keep_attendee_line?(line, wanted)
      end)

    present = MapSet.new(kept, &line_address/1)

    added =
      attendees
      |> Enum.reject(&(is_nil(attendee_address(&1)) or attendee_address(&1) in present))
      |> Enum.uniq_by(&attendee_address/1)

    lines = kept ++ added_lines(added, mode, ours)

    {replaced_attendee_properties(ours), join_lines(lines ++ marker(lines, mode, ours))}
  end

  defp keep_attendee_line?(line, wanted) do
    case line_address(line) do
      nil -> true
      address -> address in wanted
    end
  end

  # See the moduledoc: a `CONTACT` is only ever added where this module owns
  # the `CONTACT` lines, so a later removal can take it away again.
  defp added_lines(_added, :contact, false = _ours), do: []

  defp added_lines(added, mode, _ours),
    do: content_lines(Properties.build_attendee_lines(%{attendees: added}, mode))

  defp replaced_attendee_properties(true = _ours), do: @rewritten_attendee_properties
  defp replaced_attendee_properties(false = _ours), do: ["ATTENDEE"]

  defp marker(lines, :attendee, true = _ours) do
    if Enum.any?(lines, &(property_name(&1) == "ATTENDEE")),
      do: [ICalBuilder.attendee_marker()],
      else: []
  end

  defp marker(_lines, _mode, _ours), do: []

  defp join_lines([]), do: nil
  defp join_lines(lines), do: Enum.join(lines, "\r\n")

  defp line_address(line) do
    case Regex.run(@mailto, line) do
      [_match, address] -> address |> String.trim() |> String.downcase()
      nil -> nil
    end
  end

  defp attendee_address(%{"email" => email}), do: normalise_address(email)
  defp attendee_address(%{email: email}), do: normalise_address(email)
  defp attendee_address(email) when is_binary(email), do: normalise_address(email)
  defp attendee_address(_other), do: nil

  defp normalise_address(email) when is_binary(email) and email != "",
    do: email |> String.trim() |> String.downcase()

  defp normalise_address(_missing), do: nil

  defp ours?(properties) do
    not advertises_attendees?(properties) or marked_ours?(properties)
  end

  defp advertises_attendees?(properties),
    do: Enum.any?(properties, &(property_name(&1) == "ATTENDEE"))

  defp marked_ours?(properties),
    do: Enum.any?(properties, &(property_name(&1) == "X-TYMESLOT-ATTENDEES"))

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
