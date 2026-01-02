defmodule Tymeslot.Integrations.Calendar.ICalBuilder do
  @moduledoc """
  Builds iCalendar (RFC 5545) formatted data for calendar events.

  This module provides functions to create, parse, and manipulate
  iCalendar data used by CalDAV and other calendar providers.

  ## Features
  - Event creation with all standard properties
  - Timezone support
  - Recurring event support
  - Attendee management
  - Alarm/reminder support
  """

  @doc """
  Builds a complete iCalendar document for an event.

  ## Options
  - `:uid` - Unique identifier for the event (auto-generated if not provided)
  - `:summary` - Event title/summary (required)
  - `:description` - Event description
  - `:location` - Event location
  - `:start_time` - Event start time as DateTime (required)
  - `:end_time` - Event end time as DateTime (required)
  - `:all_day` - Boolean indicating if this is an all-day event
  - `:attendees` - List of attendee email addresses
  - `:organizer` - Organizer email address
  - `:status` - Event status (TENTATIVE, CONFIRMED, CANCELLED)
  - `:transparency` - OPAQUE (busy) or TRANSPARENT (free)
  - `:categories` - List of category strings
  - `:url` - Associated URL
  - `:recurrence` - Recurrence rule (RRULE) string
  - `:reminders` - List of reminder configurations

  ## Examples

      iex> ICalBuilder.build_event(%{
      ...>   summary: "Team Meeting",
      ...>   start_time: ~U[2024-01-15 10:00:00Z],
      ...>   end_time: ~U[2024-01-15 11:00:00Z],
      ...>   location: "Conference Room A"
      ...> })
      "BEGIN:VCALENDAR\\r\\nVERSION:2.0..."
  """
  @spec build_event(map()) :: String.t()
  def build_event(event_data) do
    uid = Map.get(event_data, :uid, generate_uid())

    lines = [
      "BEGIN:VCALENDAR",
      "VERSION:2.0",
      "PRODID:-//Tymeslot//Calendar Integration//EN",
      "CALSCALE:GREGORIAN",
      "METHOD:PUBLISH",
      "BEGIN:VEVENT",
      "UID:#{uid}",
      "DTSTAMP:#{format_datetime(DateTime.utc_now())}",
      build_dtstart(event_data),
      build_dtend(event_data),
      "SUMMARY:#{escape_text(event_data.summary)}",
      build_optional_properties(event_data),
      build_attendees(event_data),
      build_reminders(event_data),
      "END:VEVENT",
      "END:VCALENDAR"
    ]

    lines
    |> Enum.filter(&(&1 != nil && &1 != ""))
    |> Enum.join("\r\n")
  end

  @doc """
  Builds a minimal iCalendar document for quick event creation.

  Used for simple events without complex properties.
  """
  @spec build_simple_event(String.t(), map()) :: String.t()
  def build_simple_event(uid, event_data) do
    """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Tymeslot//CalDAV Client//EN
    BEGIN:VEVENT
    UID:#{uid}
    DTSTART:#{format_datetime(event_data.start_time)}
    DTEND:#{format_datetime(event_data.end_time)}
    SUMMARY:#{escape_text(event_data.summary)}
    DESCRIPTION:#{escape_text(event_data[:description] || "")}
    LOCATION:#{escape_text(event_data[:location] || "")}
    END:VEVENT
    END:VCALENDAR
    """
  end

  @doc """
  Generates a unique identifier for an event.

  The UID follows the format: `{random-hex}@tymeslot.com`
  """
  @spec generate_uid() :: String.t()
  def generate_uid do
    random_string = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    "#{random_string}@tymeslot.com"
  end

  @doc """
  Formats a DateTime for iCalendar format.

  Converts to UTC and formats as: YYYYMMDDTHHMMSSZ

  ## Examples

      iex> ICalBuilder.format_datetime(~U[2024-01-15 10:30:45.123456Z])
      "20240115T103045Z"
  """
  @spec format_datetime(DateTime.t()) :: String.t()
  def format_datetime(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/\.\d+/, "")
  end

  @doc """
  Formats a Date for all-day events in iCalendar format.

  ## Examples

      iex> ICalBuilder.format_date(~D[2024-01-15])
      "20240115"
  """
  @spec format_date(Date.t()) :: String.t()
  def format_date(%Date{} = date) do
    Date.to_iso8601(date, :basic)
  end

  @doc """
  Escapes text for iCalendar format.

  Handles special characters according to RFC 5545.
  """
  @spec escape_text(String.t() | nil) :: String.t()
  def escape_text(nil), do: ""

  def escape_text(text) when is_binary(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace(",", "\\,")
    |> String.replace(";", "\\;")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "")
  end

  @doc """
  Builds a recurrence rule (RRULE) string.

  ## Options
  - `:frequency` - DAILY, WEEKLY, MONTHLY, YEARLY (required)
  - `:interval` - Interval between recurrences (default: 1)
  - `:count` - Number of occurrences
  - `:until` - End date for recurrence
  - `:by_day` - List of days (MO, TU, WE, TH, FR, SA, SU)
  - `:by_month` - List of months (1-12)

  ## Examples

      iex> ICalBuilder.build_rrule(%{frequency: "WEEKLY", by_day: ["MO", "WE", "FR"]})
      "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"
  """
  @spec build_rrule(map()) :: String.t() | nil
  def build_rrule(nil), do: nil

  def build_rrule(recurrence) when is_map(recurrence) do
    parts = ["FREQ=#{recurrence[:frequency]}"]

    parts =
      if recurrence[:interval] && recurrence[:interval] > 1 do
        parts ++ ["INTERVAL=#{recurrence[:interval]}"]
      else
        parts
      end

    parts =
      if recurrence[:count] do
        parts ++ ["COUNT=#{recurrence[:count]}"]
      else
        parts
      end

    parts =
      if recurrence[:until] do
        parts ++ ["UNTIL=#{format_datetime(recurrence[:until])}"]
      else
        parts
      end

    parts =
      if recurrence[:by_day] do
        parts ++ ["BYDAY=#{Enum.join(recurrence[:by_day], ",")}"]
      else
        parts
      end

    parts =
      if recurrence[:by_month] do
        parts ++ ["BYMONTH=#{Enum.join(recurrence[:by_month], ",")}"]
      else
        parts
      end

    "RRULE:#{Enum.join(parts, ";")}"
  end

  # Private helper functions

  defp build_dtstart(%{all_day: true, start_time: start_time}) do
    date = DateTime.to_date(start_time)
    "DTSTART;VALUE=DATE:#{format_date(date)}"
  end

  defp build_dtstart(%{start_time: start_time}) do
    "DTSTART:#{format_datetime(start_time)}"
  end

  defp build_dtend(%{all_day: true, end_time: end_time}) do
    date = DateTime.to_date(end_time)
    "DTEND;VALUE=DATE:#{format_date(date)}"
  end

  defp build_dtend(%{end_time: end_time}) do
    "DTEND:#{format_datetime(end_time)}"
  end

  defp build_optional_properties(event_data) do
    []
    |> maybe_add_property(:description, event_data)
    |> maybe_add_property(:location, event_data)
    |> maybe_add_property(:status, event_data)
    |> maybe_add_property(:transparency, event_data)
    |> maybe_add_property(:categories, event_data)
    |> maybe_add_property(:url, event_data)
    |> maybe_add_property(:organizer, event_data)
    |> maybe_add_property(:recurrence, event_data)
    |> Enum.join("\r\n")
  end

  defp maybe_add_property(properties, :description, %{description: description})
       when not is_nil(description) do
    properties ++ ["DESCRIPTION:#{escape_text(description)}"]
  end

  defp maybe_add_property(properties, :location, %{location: location})
       when not is_nil(location) do
    properties ++ ["LOCATION:#{escape_text(location)}"]
  end

  defp maybe_add_property(properties, :status, %{status: status}) when not is_nil(status) do
    properties ++ ["STATUS:#{status}"]
  end

  defp maybe_add_property(properties, :transparency, %{transparency: transparency})
       when not is_nil(transparency) do
    properties ++ ["TRANSP:#{transparency}"]
  end

  defp maybe_add_property(properties, :categories, %{categories: categories})
       when not is_nil(categories) do
    categories_str = Enum.join(categories, ",")
    properties ++ ["CATEGORIES:#{escape_text(categories_str)}"]
  end

  defp maybe_add_property(properties, :url, %{url: url}) when not is_nil(url) do
    properties ++ ["URL:#{url}"]
  end

  defp maybe_add_property(properties, :organizer, %{organizer: organizer})
       when not is_nil(organizer) do
    properties ++ ["ORGANIZER:mailto:#{organizer}"]
  end

  defp maybe_add_property(properties, :recurrence, %{recurrence: recurrence})
       when not is_nil(recurrence) do
    case build_rrule(recurrence) do
      nil -> properties
      rrule -> properties ++ [rrule]
    end
  end

  defp maybe_add_property(properties, _, _), do: properties

  defp build_attendees(%{attendees: attendees}) when is_list(attendees) do
    Enum.map_join(attendees, "\r\n", fn email ->
      "ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION:mailto:#{email}"
    end)
  end

  defp build_attendees(_), do: ""

  defp build_reminders(%{reminders: reminders}) when is_list(reminders) do
    Enum.map_join(reminders, "\r\n", &build_reminder/1)
  end

  defp build_reminders(_), do: ""

  defp build_reminder(%{minutes_before: minutes, type: type}) do
    type = String.upcase(to_string(type))

    String.trim("""
    BEGIN:VALARM
    TRIGGER:-PT#{minutes}M
    ACTION:#{type}
    DESCRIPTION:Reminder
    END:VALARM
    """)
  end

  defp build_reminder(%{minutes_before: minutes}) do
    build_reminder(%{minutes_before: minutes, type: "DISPLAY"})
  end
end
