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
end
