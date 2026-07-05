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

  ## Internal structure

  The builder is split into focused sibling modules; this module orchestrates
  them and exposes the public API:

    - `__MODULE__.Format` — date/time formatting, text escaping, UID generation
    - `__MODULE__.Properties` — canonical VEVENT property-line serialisers
    - `__MODULE__.Alarms` — VALARM (reminder) serialisation
    - `__MODULE__.LineFolder` — RFC 5545 §3.1 content-line folding
  """

  alias Tymeslot.Integrations.Calendar.EventColour
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Alarms
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Format
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Properties

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
  Generates a unique identifier for an event.

  The UID follows the format: `{random-hex}@tymeslot.com`
  """
  @spec generate_uid() :: String.t()
  defdelegate generate_uid(), to: Format

  @doc """
  Formats a DateTime for iCalendar format.

  Converts to UTC and formats as: YYYYMMDDTHHMMSSZ

  ## Examples

      iex> ICalBuilder.format_datetime(~U[2024-01-15 10:30:45.123456Z])
      "20240115T103045Z"
  """
  @spec format_datetime(DateTime.t()) :: String.t()
  defdelegate format_datetime(datetime), to: Format

  @doc """
  Formats a Date for all-day events in iCalendar format.

  ## Examples

      iex> ICalBuilder.format_date(~D[2024-01-15])
      "20240115"
  """
  @spec format_date(Date.t()) :: String.t()
  defdelegate format_date(date), to: Format

  @doc """
  Escapes text for iCalendar format.

  Handles special characters according to RFC 5545.
  """
  @spec escape_text(String.t() | nil) :: String.t()
  defdelegate escape_text(text), to: Format

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
    uid = Map.get(event_data, :uid, Format.generate_uid())

    lines = [
      "BEGIN:VCALENDAR",
      "VERSION:2.0",
      "PRODID:-//Tymeslot//Calendar Integration//EN",
      "CALSCALE:GREGORIAN",
      "METHOD:PUBLISH",
      "BEGIN:VEVENT",
      "UID:#{uid}",
      "DTSTAMP:#{Format.format_datetime(DateTime.utc_now())}",
      Properties.build_dtstart(event_data),
      Properties.build_dtend(event_data),
      "SUMMARY:#{Format.escape_text(event_data.summary)}",
      build_optional_properties(event_data),
      build_attendees(event_data),
      Alarms.build_reminders(event_data),
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
          "DTSTAMP:#{Format.format_datetime(DateTime.utc_now())}",
          Properties.build_dtstart(event_data),
          Properties.build_dtend(event_data),
          "SUMMARY:#{Format.escape_text(Map.get(event_data, :summary) || "")}",
          "DESCRIPTION:#{Format.escape_text(event_data[:description] || "")}",
          "LOCATION:#{Format.escape_text(event_data[:location] || "")}",
          Properties.build_conference_line(event_data),
          Properties.build_attachment_lines(event_data),
          Properties.build_transp(event_data),
          Properties.build_status(event_data),
          Properties.build_class(event_data),
          Properties.build_colour_line(event_data),
          Properties.build_rrule_line(event_data),
          Properties.build_exdate(event_data),
          Properties.build_organizer_line(event_data),
          Properties.build_attendee_lines(event_data),
          Alarms.build_reminders(event_data),
          "END:VEVENT",
          "END:VCALENDAR"
        ],
        &(&1 == nil or &1 == "")
      )

    raw = Enum.join(lines, "\r\n") <> "\r\n"
    LineFolder.fold_lines(raw)
  end

  @doc """
  Replaces (or inserts) the RFC 7986 `COLOR` property on every `VEVENT`
  component of an existing raw iCalendar document, leaving every other
  property (RRULE, ATTENDEE, VALARM, ORGANIZER, ...) untouched.

  Used by the colour write-back path: rebuilding a bare VEVENT from a reduced
  payload (as `build_simple_event/2` does) would silently drop recurrence,
  attendee, and reminder data already present on a synced calendar entry.
  Patching the authoritative `raw_ical` last read from the provider instead
  guarantees no other field is lost.

  Returns the document unchanged when `colour` does not map to a known CSS3
  colour (see `EventColour.css_colour/1`) — nothing to patch.
  """
  @spec replace_colour_property(String.t(), String.t() | nil) :: String.t()
  def replace_colour_property(raw_ical, colour) when is_binary(raw_ical) do
    case EventColour.css_colour(colour) do
      nil ->
        raw_ical

      css_name ->
        raw_ical
        |> LineFolder.unfold_lines()
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "COLOR:")))
        |> Enum.flat_map(&inject_colour_after_vevent_begin(&1, css_name))
        |> Enum.join("\r\n")
        |> Kernel.<>("\r\n")
        |> LineFolder.fold_lines()
    end
  end

  defp inject_colour_after_vevent_begin("BEGIN:VEVENT" = line, css_name),
    do: [line, "COLOR:#{css_name}"]

  defp inject_colour_after_vevent_begin(line, _css_name), do: [line]

  @doc """
  Builds a recurrence rule (RRULE) string from a legacy string-keyed map.

  This is the *legacy* RRULE serialiser used by `build_event/1` (the
  `maybe_add_property/3` recurrence path). Its input format uses string/atom
  keys with uppercase frequency strings: `%{frequency: "WEEKLY", ...}`.

  The production CalDAV write path uses `build_simple_event/2` instead, which
  reads the canonical `recurrence_rule` string field and emits it via
  `Properties.build_rrule_line/1` (which delegates to `RRule.strip_prefix/1`).
  The two serialisers coexist because they serve different data shapes:
    - `build_rrule/1` — legacy `%{frequency: "WEEKLY", by_day: ["MO"]}` map
    - `Properties.build_rrule_line/1` → `RRule.build/2` — canonical `%{freq: :weekly, ...}` map

  Note: `build_rrule/1` always emits UNTIL as a UTC date-time even for all-day
  events. This is acceptable because the only production call site
  (`build_event/1`) is not used by the CalDAV write path. For correct all-day
  UNTIL handling on the CalDAV path, the canonical RRULE string is built via
  `RRule.build/2` with `all_day: true`.

  ## Options
  - `:frequency` - DAILY, WEEKLY, MONTHLY, YEARLY (required)
  - `:interval` - Interval between recurrences (default: 1)
  - `:count` - Number of occurrences
  - `:until` - End date/time for recurrence
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
        parts ++ ["UNTIL=#{Format.format_datetime(recurrence[:until])}"]
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

  # Optional-property assembly for the legacy `build_event/1` path. The
  # canonical CalDAV path (`build_simple_event/2`) uses the dedicated
  # serialisers in `Properties` instead.
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
    properties ++ ["DESCRIPTION:#{Format.escape_text(description)}"]
  end

  defp maybe_add_property(properties, :location, %{location: location})
       when is_binary(location) do
    properties ++ ["LOCATION:#{Format.escape_text(location)}"]
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
    properties ++ ["CATEGORIES:#{Format.escape_text(categories_str)}"]
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
    properties ++ ["ORGANIZER;SCHEDULE-AGENT=CLIENT:mailto:#{organizer}"]
  end

  defp maybe_add_property(properties, :recurrence, %{recurrence: recurrence})
       when is_map(recurrence) do
    properties ++ [build_rrule(recurrence)]
  end

  defp maybe_add_property(properties, _key, _value), do: properties

  # Legacy CONTACT serialisation for the `build_event/1` attendee list. See
  # `Properties.build_attendee_lines/1` for the canonical CalDAV path and the
  # issue #41 rationale for emitting CONTACT rather than ATTENDEE.
  defp build_attendees(%{attendees: attendees}) when is_list(attendees) do
    Enum.map_join(attendees, "\r\n", fn
      %{"email" => email} ->
        "CONTACT:#{Format.sanitize_ical_value(email)}"

      %{email: email} ->
        "CONTACT:#{Format.sanitize_ical_value(email)}"

      email when is_binary(email) ->
        "CONTACT:#{Format.sanitize_ical_value(email)}"
    end)
  end

  defp build_attendees(_no_attendees), do: ""
end
