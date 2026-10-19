defmodule Tymeslot.Integrations.Calendar.Outlook.EventMapper do
  @moduledoc """
  Maps outbound event data from Tymeslot's internal format to
  Microsoft Graph API format for Outlook Calendar operations.
  """

  alias Tymeslot.Integrations.Calendar.Attendee
  alias Tymeslot.Integrations.Calendar.EventTimeFormatter
  alias Tymeslot.Integrations.Calendar.Outlook.RecurrenceConverter
  alias Tymeslot.Integrations.Calendar.Outlook.TymeslotFingerprint
  alias Tymeslot.Integrations.Calendar.Reminder
  alias Tymeslot.Timezones.WindowsZones

  @doc """
  Converts Tymeslot event data into the Microsoft Graph event format.

  A repeat rule Graph has no pattern for, or one Graph would write with
  other dates (`{:error, :day_missing_in_some_months}`), is refused rather
  than written as another (see `Outlook.RecurrenceConverter`).
  """
  @spec format_event_data(map()) ::
          {:ok, map()}
          | {:error, :rule_not_supported_by_outlook | :day_missing_in_some_months}
  def format_event_data(event_data) do
    base = %{
      "subject" => extract_field(event_data, :summary, "summary"),
      "body" => build_event_body(event_data),
      "location" => build_event_location(event_data),
      "start" => build_event_datetime(event_data, :start_time, "start_time"),
      "end" => build_event_datetime(event_data, :end_time, "end_time"),
      "showAs" => map_show_as(event_data),
      "sensitivity" => map_sensitivity(event_data),
      "attendees" => build_attendees(event_data)
    }

    base =
      if all_day_event?(event_data),
        do: Map.put(base, "isAllDay", true),
        else: base

    with {:ok, recurrence} <- recurrence(event_data) do
      {:ok,
       base
       |> add_reminder(event_data)
       |> Map.put("recurrence", recurrence)
       |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
       |> Map.new()}
    end
  end

  @doc """
  Adds the Tymeslot fingerprint extended property to a Graph API event body,
  so that events created by Tymeslot can be identified later during sync.
  """
  @spec add_tymeslot_fingerprint(map()) :: map()
  def add_tymeslot_fingerprint(body) do
    Map.put(body, "singleValueExtendedProperties", [
      %{"id" => TymeslotFingerprint.property_id(), "value" => "tymeslot"}
    ])
  end

  # Private helpers

  # Graph's `PATCH` replaces the event's whole `attendees` collection with the
  # one it is sent, and an attendee's `status` cannot be written: Graph fills
  # it from the replies the organiser received and ignores it on a request
  # body. Every attendee in a PATCH therefore comes back with no reply, so the
  # collection is sent only when the caller supplied one, which the grid does
  # only for an edit that changes the guest list (see
  # `Tymeslot.CalendarGrid.EventEdit`). A supplied empty list is still sent,
  # because it is the removal of the last guest; a payload that says nothing
  # about attendees leaves Graph's list, and its replies, alone.
  defp build_attendees(event_data) do
    case extract_field(event_data, :attendees, "attendees") do
      [_first | _rest] = attendees ->
        attendees
        |> Enum.map(&Attendee.normalise/1)
        |> Enum.map(&graph_attendee(&1.email, &1.display_name))
        |> Enum.reject(&is_nil/1)

      _none ->
        legacy_attendees(event_data)
    end
  end

  # Legacy single-attendee path (ad-hoc meetings), which names the invitee on
  # the event itself rather than in an attendee list.
  defp legacy_attendees(event_data) do
    case extract_field(event_data, :attendee_email, "attendee_email") do
      email when is_binary(email) ->
        [graph_attendee(email, extract_field(event_data, :attendee_name, "attendee_name"))]

      _none ->
        supplied_empty_list(event_data)
    end
  end

  defp supplied_empty_list(event_data) do
    case extract_field(event_data, :attendees, "attendees") do
      [] -> []
      _no_opinion -> nil
    end
  end

  defp graph_attendee(email, name) when is_binary(email) do
    %{"emailAddress" => %{"address" => email, "name" => name || email}, "type" => "required"}
  end

  defp graph_attendee(_no_email, _name), do: nil

  defp extract_field(event_data, atom_key, string_key) do
    Map.get(event_data, atom_key) || Map.get(event_data, string_key)
  end

  defp build_event_body(event_data) do
    %{
      "contentType" => "Text",
      "content" => extract_field(event_data, :description, "description") || ""
    }
  end

  defp build_event_location(event_data) do
    %{
      "displayName" => extract_field(event_data, :location, "location") || ""
    }
  end

  defp build_event_datetime(event_data, atom_key, string_key) do
    datetime = extract_field(event_data, atom_key, string_key)
    timezone = extract_field(event_data, :timezone, "timezone")

    case datetime do
      %Date{} = date ->
        # Outlook requires dateTime format even for all-day events
        %{
          "dateTime" => "#{Date.to_iso8601(date)}T00:00:00.0000000",
          "timeZone" => timezone || "UTC"
        }

      _other ->
        datetime
        |> EventTimeFormatter.format_with_timezone(timezone,
          include_when_missing?: true,
          include_timezone_on_error?: true
        )
        |> series_zone_name(event_data)
    end
  end

  # Graph accepts every Windows zone name but only some IANA ones, so a
  # series, which Graph expands in the zone it is given, is written with the
  # Windows zone that keeps its offsets. The wall clock stays the IANA zone's.
  defp series_zone_name(%{"timeZone" => zone} = value, event_data) when is_binary(zone) do
    case extract_field(event_data, :recurrence_rule, "recurrence_rule") do
      rule when is_binary(rule) and rule != "" ->
        %{value | "timeZone" => WindowsZones.from_iana(zone, series_start(event_data))}

      _one_off ->
        value
    end
  end

  defp series_zone_name(value, _event_data), do: value

  defp series_start(event_data) do
    case extract_field(event_data, :start_time, "start_time") do
      %DateTime{} = start -> start
      _other -> DateTime.utc_now()
    end
  end

  defp map_show_as(event_data) do
    transparency = extract_field(event_data, :transparency, "transparency")
    status = extract_field(event_data, :status, "status")

    cond do
      transparency in [:transparent, "transparent"] -> "free"
      status in [:tentative, "tentative"] -> "tentative"
      true -> "busy"
    end
  end

  defp map_sensitivity(event_data) do
    case extract_field(event_data, :visibility, "visibility") do
      v when v in [:private, "private"] -> "private"
      v when v in [:confidential, "confidential"] -> "confidential"
      _other -> nil
    end
  end

  defp all_day_event?(event_data) do
    start_time = extract_field(event_data, :start_time, "start_time")
    match?(%Date{}, start_time)
  end

  # Microsoft Graph models a single lead-time reminder per event via
  # `reminderMinutesBeforeStart` + `isReminderOn` — it has no per-reminder
  # method and cannot represent multiple reminders. Only the first reminder's
  # lead time round-trips; additional reminders are dropped on the Outlook path.
  defp add_reminder(base, event_data) do
    case extract_field(event_data, :reminders, "reminders") do
      [first | _rest] when is_map(first) ->
        base
        |> Map.put("isReminderOn", true)
        |> Map.put("reminderMinutesBeforeStart", Reminder.minutes_before(first))

      _none ->
        Map.put(base, "isReminderOn", false)
    end
  end

  # Microsoft Graph requires a structured `recurrence` object (pattern + range)
  # rather than an RRULE string; the converter builds it from the canonical
  # `recurrence_rule` field. The range needs the event's start date, derived from
  # `start_time` (a Date for all-day events, otherwise a DateTime). Omitted when
  # no rule is present or the start date cannot be determined.
  defp recurrence(event_data) do
    rrule = extract_field(event_data, :recurrence_rule, "recurrence_rule")
    timezone = extract_field(event_data, :timezone, "timezone")

    with rrule when is_binary(rrule) and rrule != "" <- rrule,
         %Date{} = start_date <- recurrence_start_date(event_data, timezone) do
      RecurrenceConverter.rrule_to_outlook(rrule, start_date, timezone)
    else
      _none -> {:ok, nil}
    end
  end

  # Graph reads the range's `startDate`, and the weekday a weekly pattern
  # falls back to, in the event's own zone: 08:00 on a Monday in Tokyo is
  # Sunday in UTC.
  defp recurrence_start_date(event_data, timezone) do
    case extract_field(event_data, :start_time, "start_time") do
      %Date{} = date -> date
      %DateTime{} = dt -> dt |> local_in(timezone) |> DateTime.to_date()
      _other -> nil
    end
  end

  defp local_in(datetime, timezone) when is_binary(timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, local} -> local
      {:error, _reason} -> datetime
    end
  end

  defp local_in(datetime, _timezone), do: datetime
end
