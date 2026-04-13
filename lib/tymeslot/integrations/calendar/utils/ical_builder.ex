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

  @type ical_event_data :: %{
          required(:summary) => String.t(),
          required(:start_time) => DateTime.t(),
          required(:end_time) => DateTime.t(),
          optional(:uid) => String.t(),
          optional(:location) => String.t(),
          optional(:attendees) => [String.t()],
          optional(:organizer) => String.t(),
          optional(:status) => String.t(),
          optional(:transparency) => String.t(),
          optional(:categories) => [String.t()],
          optional(:url) => String.t(),
          optional(:recurrence) => String.t(),
          optional(:reminders) => [map()]
        }

  @type simple_event_data :: %{
          required(:start_time) => DateTime.t(),
          required(:end_time) => DateTime.t(),
          required(:summary) => String.t(),
          optional(:description) => String.t(),
          optional(:location) => String.t()
        }

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
  @spec build_event(ical_event_data()) :: String.t()
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

  Timed events are always serialised in UTC with a `Z` suffix — Tymeslot
  deliberately avoids TZID / VTIMEZONE emission because a spec-compliant
  VTIMEZONE body (RFC 5545 §3.6.5) requires authored STANDARD/DAYLIGHT
  subcomponents with real TZOFFSETFROM/TO and RRULE rules, which we don't
  generate from our tzdata-backed clock. Stricter CalDAV servers (Radicale's
  vobject) reject a VTIMEZONE without those subcomponents as HTTP 400. The
  UTC wall-clock is preserved correctly, and the per-user timezone label is
  reconstructed at display time from the user's profile timezone — the iCal
  payload never drives user-facing labels.
  """
  @spec build_simple_event(String.t(), simple_event_data() | map()) :: String.t()
  def build_simple_event(uid, event_data) do
    lines =
      Enum.reject(
        [
          "BEGIN:VCALENDAR",
          "VERSION:2.0",
          "PRODID:-//Tymeslot//CalDAV Client//EN",
          "BEGIN:VEVENT",
          "UID:#{uid}",
          "DTSTAMP:#{format_datetime(DateTime.utc_now())}",
          build_dtstart(event_data),
          build_dtend(event_data),
          "SUMMARY:#{escape_text(Map.get(event_data, :summary) || "")}",
          "DESCRIPTION:#{escape_text(event_data[:description] || "")}",
          "LOCATION:#{escape_text(event_data[:location] || "")}",
          build_transp(event_data),
          build_status(event_data),
          build_class(event_data),
          build_rrule_line(event_data),
          build_exdate(event_data),
          build_attendee_lines(event_data),
          "END:VEVENT",
          "END:VCALENDAR"
        ],
        &(&1 == nil or &1 == "")
      )

    Enum.join(lines, "\r\n") <> "\r\n"
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

  @valid_statuses ~w[TENTATIVE CONFIRMED CANCELLED]
  @valid_transparencies ~w[OPAQUE TRANSPARENT]
  @valid_visibilities ~w[PUBLIC PRIVATE CONFIDENTIAL]

  # Private helper functions

  defp build_dtstart(%{start_time: %Date{} = date}) do
    "DTSTART;VALUE=DATE:#{format_date(date)}"
  end

  defp build_dtstart(%{all_day: true, start_time: start_time}) do
    date = DateTime.to_date(start_time)
    "DTSTART;VALUE=DATE:#{format_date(date)}"
  end

  defp build_dtstart(%{start_time: %NaiveDateTime{} = ndt}) do
    "DTSTART:#{format_naive_datetime(ndt)}"
  end

  defp build_dtstart(%{start_time: %DateTime{} = dt}) do
    "DTSTART:#{format_datetime(DateTime.shift_zone!(dt, "Etc/UTC"))}"
  end

  defp build_dtstart(%{start_time: start_time}) do
    "DTSTART:#{format_datetime(start_time)}"
  end

  defp build_dtend(%{end_time: %Date{} = date}) do
    "DTEND;VALUE=DATE:#{format_date(date)}"
  end

  defp build_dtend(%{all_day: true, end_time: end_time}) do
    date = DateTime.to_date(end_time)
    "DTEND;VALUE=DATE:#{format_date(date)}"
  end

  defp build_dtend(%{end_time: %NaiveDateTime{} = ndt}) do
    "DTEND:#{format_naive_datetime(ndt)}"
  end

  defp build_dtend(%{end_time: %DateTime{} = dt}) do
    "DTEND:#{format_datetime(DateTime.shift_zone!(dt, "Etc/UTC"))}"
  end

  defp build_dtend(%{end_time: end_time}) do
    "DTEND:#{format_datetime(end_time)}"
  end

  defp build_transp(%{transparency: t}) when t in [:transparent, "transparent", "TRANSPARENT"],
    do: "TRANSP:TRANSPARENT"

  defp build_transp(%{transparency: t}) when t in [:opaque, "opaque", "OPAQUE"],
    do: "TRANSP:OPAQUE"

  defp build_transp(_event), do: nil

  defp build_status(%{status: s}) when s in [:tentative, "tentative", "TENTATIVE"],
    do: "STATUS:TENTATIVE"

  defp build_status(%{status: s}) when s in [:confirmed, "confirmed", "CONFIRMED"],
    do: "STATUS:CONFIRMED"

  defp build_status(%{status: s}) when s in [:cancelled, "cancelled", "CANCELLED"],
    do: "STATUS:CANCELLED"

  defp build_status(_event), do: nil

  defp build_class(%{visibility: v}) when v in [:public, "public", "PUBLIC"], do: "CLASS:PUBLIC"

  defp build_class(%{visibility: v}) when v in [:private, "private", "PRIVATE"],
    do: "CLASS:PRIVATE"

  defp build_class(%{visibility: v}) when v in [:confidential, "confidential", "CONFIDENTIAL"],
    do: "CLASS:CONFIDENTIAL"

  defp build_class(_event), do: nil

  defp build_rrule_line(%{recurrence_rule: rrule}) when is_binary(rrule) and rrule != "",
    do: "RRULE:#{rrule}"

  defp build_rrule_line(_event), do: nil

  # EXDATE's value type MUST match DTSTART's (RFC 5545 §3.8.5.1). If the
  # master event is a DATE-TIME (timed event), bare Date exceptions are
  # promoted to UTC DateTimes at DTSTART's time-of-day. If the master is a
  # DATE (all-day event), we emit `;VALUE=DATE`.
  defp build_exdate(%{recurrence_exceptions: dates, start_time: %DateTime{} = start_dt})
       when is_list(dates) and dates != [] do
    start_utc = DateTime.shift_zone!(start_dt, "Etc/UTC")
    time_of_day = DateTime.to_time(start_utc)

    formatted =
      Enum.map_join(dates, ",", fn
        %Date{} = d ->
          d
          |> DateTime.new!(time_of_day, "Etc/UTC")
          |> format_datetime()

        %DateTime{} = dt ->
          dt |> DateTime.shift_zone!("Etc/UTC") |> format_datetime()
      end)

    "EXDATE:#{formatted}"
  end

  defp build_exdate(%{recurrence_exceptions: dates, start_time: %Date{}})
       when is_list(dates) and dates != [] do
    formatted =
      Enum.map_join(dates, ",", fn
        %Date{} = d -> format_date(d)
      end)

    "EXDATE;VALUE=DATE:#{formatted}"
  end

  defp build_exdate(_event), do: nil

  defp build_attendee_lines(%{attendees: attendees})
       when is_list(attendees) and attendees != [] do
    attendees
    |> Enum.map(&format_attendee/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\r\n")
  end

  defp build_attendee_lines(%{attendee_email: email} = event) when is_binary(email) do
    name = Map.get(event, :attendee_name)
    format_attendee(%{email: email, name: name})
  end

  defp build_attendee_lines(_event), do: nil

  defp format_attendee(%{"email" => email} = a),
    do: format_attendee(%{email: email, name: a["name"]})

  defp format_attendee(%{email: email} = a) when is_binary(email) do
    cn = a[:name] || email

    "ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;CN=#{escape_text(cn)}:mailto:#{sanitize_ical_value(email)}"
  end

  defp format_attendee(email) when is_binary(email) do
    "ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION:mailto:#{sanitize_ical_value(email)}"
  end

  defp format_attendee(_other), do: nil

  defp format_naive_datetime(%NaiveDateTime{} = ndt) do
    ndt
    |> NaiveDateTime.to_iso8601(:basic)
    |> String.replace(~r/\.\d+/, "")
  end

  defp build_optional_properties(event_data) do
    []
    |> maybe_add_property(:description, event_data)
    |> maybe_add_property(:location, event_data)
    |> maybe_add_property(:status, event_data)
    |> maybe_add_property(:transparency, event_data)
    |> maybe_add_property(:categories, event_data)
    |> maybe_add_property(:url, event_data)
    |> maybe_add_property(:visibility, event_data)
    |> maybe_add_property(:organizer, event_data)
    |> maybe_add_property(:recurrence, event_data)
    |> Enum.join("\r\n")
  end

  defp maybe_add_property(properties, :description, %{description: description})
       when is_binary(description) do
    properties ++ ["DESCRIPTION:#{escape_text(description)}"]
  end

  defp maybe_add_property(properties, :location, %{location: location})
       when is_binary(location) do
    properties ++ ["LOCATION:#{escape_text(location)}"]
  end

  defp maybe_add_property(properties, :status, %{status: status})
       when is_binary(status) or is_atom(status) do
    value = status |> to_string() |> String.upcase()

    if value in @valid_statuses do
      properties ++ ["STATUS:#{value}"]
    else
      properties
    end
  end

  defp maybe_add_property(properties, :transparency, %{transparency: transparency})
       when is_binary(transparency) or is_atom(transparency) do
    value = transparency |> to_string() |> String.upcase()

    if value in @valid_transparencies do
      properties ++ ["TRANSP:#{value}"]
    else
      properties
    end
  end

  defp maybe_add_property(properties, :categories, %{categories: categories})
       when is_list(categories) do
    categories_str = Enum.join(categories, ",")
    properties ++ ["CATEGORIES:#{escape_text(categories_str)}"]
  end

  defp maybe_add_property(properties, :url, %{url: url}) when is_binary(url) do
    properties ++ ["URL:#{url}"]
  end

  defp maybe_add_property(properties, :visibility, %{visibility: visibility})
       when is_binary(visibility) or is_atom(visibility) do
    value = visibility |> to_string() |> String.upcase()

    if value in @valid_visibilities do
      properties ++ ["CLASS:#{value}"]
    else
      properties
    end
  end

  defp maybe_add_property(properties, :organizer, %{organizer: organizer})
       when is_binary(organizer) do
    properties ++ ["ORGANIZER:mailto:#{organizer}"]
  end

  defp maybe_add_property(properties, :recurrence, %{recurrence: recurrence})
       when is_map(recurrence) do
    case build_rrule(recurrence) do
      nil -> properties
      rrule -> properties ++ [rrule]
    end
  end

  defp maybe_add_property(properties, _key, _value), do: properties

  defp build_attendees(%{attendees: attendees}) when is_list(attendees) do
    Enum.map_join(attendees, "\r\n", fn
      %{"email" => email} ->
        "ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION:mailto:#{sanitize_ical_value(email)}"

      %{email: email} ->
        "ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION:mailto:#{sanitize_ical_value(email)}"

      email when is_binary(email) ->
        "ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION:mailto:#{sanitize_ical_value(email)}"
    end)
  end

  defp build_attendees(_no_attendees), do: ""

  defp build_reminders(%{reminders: reminders}) when is_list(reminders) do
    Enum.map_join(reminders, "\r\n", &build_reminder/1)
  end

  defp build_reminders(_no_reminders), do: ""

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

  defp sanitize_ical_value(value) when is_binary(value) do
    String.replace(value, ~r/[\r\n\x00-\x1f]/, "")
  end

  defp sanitize_ical_value(value), do: value
end
