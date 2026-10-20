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
    - `__MODULE__.Patcher` — property-level patching of a stored document

  ## Building versus patching

  `build_simple_event/3` serialises a whole event from Tymeslot's payload and
  is the writer for an event Tymeslot authors. `patch_event_properties/3`
  rewrites named properties of a document the provider already holds and is
  the writer for an event that arrived by sync, where everything the payload
  does not model has to survive the write.
  """

  alias Tymeslot.Integrations.Calendar.CalDAV.Scheduling
  alias Tymeslot.Integrations.Calendar.EventColour
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Alarms
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Format
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Patcher
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Properties
  alias Tymeslot.Integrations.Calendar.ICalBuilder.TimeZoneComponent

  # Emitted alongside an ATTENDEE block Tymeslot authored, and read back by
  # `Patcher` to tell it apart from the organiser's own.
  @attendee_marker "X-TYMESLOT-ATTENDEES:1"

  @doc false
  @spec attendee_marker() :: String.t()
  def attendee_marker, do: @attendee_marker

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

  A timed event is serialised in UTC with a `Z` suffix, except a timed
  series given its zone in `:series_timezone` (`TimeZoneComponent.series_zone/1`):
  its `DTSTART`, `DTEND` and `EXDATE` are wall clocks in that zone, with a
  `VTIMEZONE` built from the time zone database beside them, because RFC 5545
  expands a rule in its `DTSTART`'s zone and a UTC series would move by an
  hour across every DST change. The `VTIMEZONE` lists each offset change
  with its full `STANDARD`/`DAYLIGHT` subcomponent, which strict servers
  (Radicale's vobject) require.

  The `mode` decides whether the attendee is advertised as a real `ATTENDEE`
  (beside the organiser, for a server that would otherwise add its owner) or
  as the `CONTACT` fallback; `CalDAV.Scheduling.attendee_mode/1` owns that
  choice per server. It defaults to `:contact`, the conservative answer, so a
  caller that has no client in hand cannot accidentally ask a scheduling-happy
  server to mail everyone.
  """
  @spec build_simple_event(String.t(), simple_event_data() | map(), Scheduling.mode()) ::
          String.t()
  def build_simple_event(uid, event_data, mode \\ :contact) do
    zone = TimeZoneComponent.series_zone(event_data)

    lines =
      Enum.reject(
        [
          "BEGIN:VCALENDAR",
          "VERSION:2.0",
          "PRODID:-//Tymeslot//CalDAV Client//EN"
        ] ++
          time_zone_lines(event_data, zone) ++
          [
            "BEGIN:VEVENT",
            "UID:#{uid}",
            "DTSTAMP:#{Format.format_datetime(DateTime.utc_now())}",
            Properties.build_dtstart(event_data, zone),
            Properties.build_dtend(event_data, zone),
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
            Properties.build_exdate(event_data, zone),
            Properties.build_organizer_line(event_data, mode),
            Properties.build_attendee_lines(event_data, mode),
            attendee_marker(event_data, mode),
            Alarms.build_reminders(event_data),
            "END:VEVENT",
            "END:VCALENDAR"
          ],
        &(&1 == nil or &1 == "")
      )

    raw = Enum.join(lines, "\r\n") <> "\r\n"
    LineFolder.fold_lines(raw)
  end

  defp time_zone_lines(_event_data, nil), do: []
  defp time_zone_lines(event_data, zone), do: TimeZoneComponent.for_series(event_data, zone) || []

  @doc """
  Applies the property changes `event_data` describes to an existing raw
  iCalendar document, leaving every other line exactly as the provider sent
  it.

  Each payload key owns one property, so a key the payload does not carry
  leaves its property alone and a key it carries with an empty value deletes
  it. `ATTENDEE` blocks, `CATEGORIES`, `SEQUENCE`, `X-` properties and
  anything else Tymeslot does not model survive the write, which
  `build_simple_event/3` cannot promise: it serialises the payload and
  nothing else. See `Tymeslot.Integrations.Calendar.ICalBuilder.Patcher` for the full contract, including
  which components are deliberately left untouched.
  """
  @spec patch_event_properties(String.t(), map(), Scheduling.mode()) :: String.t()
  defdelegate patch_event_properties(raw_ical, event_data, mode \\ :contact),
    to: Patcher,
    as: :patch

  @doc """
  Replaces (or inserts) the RFC 7986 `COLOR` property on the `VEVENT`
  component of an existing raw iCalendar document, leaving every other
  property (RRULE, ATTENDEE, VALARM, ORGANIZER, ...) untouched.

  Used by the colour write-back path: rebuilding a bare VEVENT from a reduced
  payload (as `build_simple_event/3` does) would silently drop recurrence,
  attendee, and reminder data already present on a synced calendar entry.
  Patching the authoritative `raw_ical` last read from the provider instead
  guarantees no other field is lost.

  Returns the document unchanged when `colour` does not map to a known CSS3
  colour (see `EventColour.css_colour/1`) — nothing to patch.
  """
  @spec replace_colour_property(String.t(), String.t() | nil) :: String.t()
  def replace_colour_property(raw_ical, colour) when is_binary(raw_ical) do
    case EventColour.css_colour(colour) do
      nil -> raw_ical
      _css_name -> Patcher.patch(raw_ical, %{colour: colour})
    end
  end

  # An `ATTENDEE` block is ambiguous on the way back in: it is either one
  # Tymeslot wrote or one the organiser's own calendar client did, and the
  # patcher must rewrite the first and never touch the second (see
  # `Patcher`'s "What is left alone"). This marks ours. `X-` properties are
  # preserved across patches, so the mark survives for as long as the block
  # it describes.
  defp attendee_marker(_event_data, :contact), do: nil

  defp attendee_marker(event_data, mode) do
    if Properties.build_attendee_lines(event_data, mode), do: @attendee_marker
  end
end
