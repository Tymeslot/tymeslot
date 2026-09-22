defmodule Tymeslot.Integrations.Calendar.ICalBuilder.Properties do
  @moduledoc """
  VEVENT property-line serialisers for the canonical event shape.

  Each public function maps one field of the canonical event map to its RFC
  5545 / RFC 7986 property line — or `nil` when the field is absent — for
  assembly by `ICalBuilder.build_simple_event/3`.
  """

  import Tymeslot.Integrations.Calendar.ICalBuilder.Format,
    only: [
      format_date: 1,
      format_datetime: 1,
      format_naive_datetime: 1,
      escape_text: 1,
      sanitize_ical_value: 1
    ]

  alias Tymeslot.Integrations.Calendar.Attendee
  alias Tymeslot.Integrations.Calendar.CalDAV.Scheduling
  alias Tymeslot.Integrations.Calendar.EventColour
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule

  @spec build_dtstart(map()) :: String.t()
  def build_dtstart(%{start_time: %Date{} = date}) do
    "DTSTART;VALUE=DATE:#{format_date(date)}"
  end

  def build_dtstart(%{all_day: true, start_time: start_time}) do
    date = DateTime.to_date(start_time)
    "DTSTART;VALUE=DATE:#{format_date(date)}"
  end

  def build_dtstart(%{start_time: %NaiveDateTime{} = ndt}) do
    "DTSTART:#{format_naive_datetime(ndt)}"
  end

  def build_dtstart(%{start_time: %DateTime{} = dt}) do
    "DTSTART:#{format_datetime(DateTime.shift_zone!(dt, "Etc/UTC"))}"
  end

  # RFC 5545 §3.6.1: for a DATE-form DTEND (all-day event), the value is
  # exclusive — the event ends at the start of that day, not during it. A
  # single-day all-day event therefore has DTEND = DTSTART + 1.
  #
  # The production CalDAV create path (create_execution.ex) already adds +1
  # before calling this function, so in practice `end_time` is always
  # exclusive. This guard catches callers that supply `end_time == start_time`
  # (e.g. direct test callers or future create paths that forget to add +1),
  # ensuring we never silently emit a zero-length all-day event.
  @spec build_dtend(map()) :: String.t()
  def build_dtend(%{end_time: %Date{} = date, start_time: %Date{} = start}) do
    exclusive = if Date.compare(date, start) == :eq, do: Date.add(date, 1), else: date
    "DTEND;VALUE=DATE:#{format_date(exclusive)}"
  end

  def build_dtend(%{end_time: %Date{} = date}) do
    "DTEND;VALUE=DATE:#{format_date(date)}"
  end

  def build_dtend(%{all_day: true, end_time: end_time, start_time: start_time}) do
    end_date = DateTime.to_date(end_time)
    start_date = DateTime.to_date(start_time)

    exclusive =
      if Date.compare(end_date, start_date) == :eq, do: Date.add(end_date, 1), else: end_date

    "DTEND;VALUE=DATE:#{format_date(exclusive)}"
  end

  def build_dtend(%{all_day: true, end_time: end_time}) do
    date = DateTime.to_date(end_time)
    "DTEND;VALUE=DATE:#{format_date(date)}"
  end

  def build_dtend(%{end_time: %NaiveDateTime{} = ndt}) do
    "DTEND:#{format_naive_datetime(ndt)}"
  end

  def build_dtend(%{end_time: %DateTime{} = dt}) do
    "DTEND:#{format_datetime(DateTime.shift_zone!(dt, "Etc/UTC"))}"
  end

  # RFC 7986 §5.11 — advertise the video-meeting access URI as a first-class
  # CONFERENCE property so RFC 7986-aware clients render a native "Join"
  # affordance. LOCATION still carries the URL for older clients. The value is
  # a URI, so it is not text-escaped; we only strip control characters to
  # prevent property injection. LABEL is omitted here (unlike the email-side
  # generator) because the CalDAV write path has no attendee-locale context.
  @spec build_conference_line(map()) :: String.t() | nil
  def build_conference_line(%{conference_url: url}) when is_binary(url) and url != "" do
    "CONFERENCE;VALUE=URI;FEATURE=VIDEO:#{sanitize_ical_value(url)}"
  end

  def build_conference_line(_event), do: nil

  # RFC 5545 §3.8.1.1 — one `ATTACH` line per file, as a URI reference (not
  # inline binary, which would bloat the payload). `FMTTYPE` carries the MIME
  # type when known. Hosted at a Tymeslot `/uploads/...` URL.
  @spec build_attachment_lines(map()) :: String.t() | nil
  def build_attachment_lines(%{attachments: attachments}) when is_list(attachments) do
    lines =
      attachments
      |> Enum.map(&attachment_line/1)
      |> Enum.reject(&is_nil/1)

    case lines do
      [] -> nil
      lines -> Enum.join(lines, "\r\n")
    end
  end

  def build_attachment_lines(_event), do: nil

  defp attachment_line(%{url: url} = attachment) when is_binary(url) and url != "" do
    case content_type(attachment) do
      nil -> "ATTACH:#{sanitize_ical_value(url)}"
      mime -> "ATTACH;FMTTYPE=#{mime}:#{sanitize_ical_value(url)}"
    end
  end

  defp attachment_line(_other), do: nil

  # Attachments reach the builder atom-keyed from the domain layer and
  # string-keyed when they have been round-tripped through JSONB, so both
  # shapes are answered here once.
  defp content_type(%{content_type: mime}) when is_binary(mime) and mime != "", do: mime
  defp content_type(%{"content_type" => mime}) when is_binary(mime) and mime != "", do: mime
  defp content_type(_attachment), do: nil

  @spec build_transp(map()) :: String.t() | nil
  def build_transp(%{transparency: t}) when t in [:transparent, "transparent", "TRANSPARENT"],
    do: "TRANSP:TRANSPARENT"

  def build_transp(%{transparency: t}) when t in [:opaque, "opaque", "OPAQUE"],
    do: "TRANSP:OPAQUE"

  def build_transp(_event), do: nil

  @spec build_status(map()) :: String.t() | nil
  def build_status(%{status: s}) when s in [:tentative, "tentative", "TENTATIVE"],
    do: "STATUS:TENTATIVE"

  def build_status(%{status: s}) when s in [:confirmed, "confirmed", "CONFIRMED"],
    do: "STATUS:CONFIRMED"

  def build_status(%{status: s}) when s in [:cancelled, "cancelled", "CANCELLED"],
    do: "STATUS:CANCELLED"

  def build_status(_event), do: nil

  @spec build_class(map()) :: String.t() | nil
  def build_class(%{visibility: v}) when v in [:public, "public", "PUBLIC"], do: "CLASS:PUBLIC"

  def build_class(%{visibility: v}) when v in [:private, "private", "PRIVATE"],
    do: "CLASS:PRIVATE"

  def build_class(%{visibility: v}) when v in [:confidential, "confidential", "CONFIDENTIAL"],
    do: "CLASS:CONFIDENTIAL"

  def build_class(_event), do: nil

  # Emits the RFC 7986 COLOR property from the canonical `:colour` palette key,
  # mapped to a CSS3 colour name. An unrecognised value (e.g. a raw inbound
  # provider colour) maps to nil and is omitted.
  @spec build_colour_line(map()) :: String.t() | nil
  def build_colour_line(%{colour: colour}) do
    case EventColour.css_colour(colour) do
      nil -> nil
      css_name -> "COLOR:#{css_name}"
    end
  end

  def build_colour_line(_event), do: nil

  # The canonical `recurrence_rule` may arrive bare (CalDAV/Outlook) or with a
  # leading `RRULE:` (Google's normaliser keeps the prefix on read); strip any
  # existing prefix so exactly one is emitted.
  @spec build_rrule_line(map()) :: String.t() | nil
  def build_rrule_line(%{recurrence_rule: rrule}) when is_binary(rrule) and rrule != "",
    do: "RRULE:#{RRule.strip_prefix(rrule)}"

  def build_rrule_line(_event), do: nil

  # EXDATE's value type MUST match DTSTART's (RFC 5545 §3.8.5.1). If the
  # master event is a DATE-TIME (timed event), bare Date exceptions are
  # promoted to UTC DateTimes at DTSTART's time-of-day. If the master is a
  # DATE (all-day event), we emit `;VALUE=DATE`.
  @spec build_exdate(map()) :: String.t() | nil
  def build_exdate(%{recurrence_exceptions: dates, start_time: %DateTime{} = start_dt})
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

  def build_exdate(%{recurrence_exceptions: dates, start_time: %Date{}})
      when is_list(dates) and dates != [] do
    formatted =
      Enum.map_join(dates, ",", fn
        %Date{} = d -> format_date(d)
      end)

    "EXDATE;VALUE=DATE:#{formatted}"
  end

  def build_exdate(_event), do: nil

  # Which property carries the attendee is the server's call, not this
  # module's: `CalDAV.Scheduling.attendee_mode/1` weighs the two failure modes
  # (issues #41 and #123) per server and this serialises its answer.
  #
  # `:attendee` emits `ATTENDEE;SCHEDULE-AGENT=CLIENT`, the RFC 6638 §7.1 way
  # to say "stored, but don't mail them — I already did". `:contact` emits
  # `CONTACT` (RFC 5545 §3.8.4.2), which carries the same name and address
  # outside the iTIP model entirely, for a server that ignores the parameter
  # and would invite the attendee a second time.
  #
  # Either way the attendee identity is also folded into the event DESCRIPTION
  # (see `CalendarEventBuilder.build_event_description/1`), which is what
  # Google and Outlook events carry too, and the only form that renders in a
  # client showing neither property.
  @spec build_attendee_lines(map(), Scheduling.mode()) :: String.t() | nil
  def build_attendee_lines(event, mode \\ :contact)

  def build_attendee_lines(%{attendees: attendees}, mode)
      when is_list(attendees) and attendees != [] do
    attendees
    |> Enum.map(&format_attendee(&1, mode))
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\r\n")
  end

  def build_attendee_lines(%{attendee_email: email} = event, mode) when is_binary(email) do
    format_attendee(
      Attendee.new(email: email, display_name: Map.get(event, :attendee_name)),
      mode
    )
  end

  def build_attendee_lines(_event, _mode), do: nil

  defp format_attendee(%{} = attendee, mode) do
    case Attendee.normalise(attendee) do
      %{email: email, display_name: name} when is_binary(email) and email != "" ->
        attendee_property(sanitize_ical_value(email), name, mode)

      _no_address ->
        nil
    end
  end

  defp format_attendee(email, mode) when is_binary(email) and email != "" do
    attendee_property(sanitize_ical_value(email), nil, mode)
  end

  defp format_attendee(_other, _mode), do: nil

  # PARTSTAT=NEEDS-ACTION is the honest starting state: the attendee booked
  # through Tymeslot, which is not an RSVP to this calendar entry. RSVP=FALSE
  # says not to chase one, since the server was just told not to send the
  # invitation that would ask.
  defp attendee_property(email, name, :attendee) do
    params = "SCHEDULE-AGENT=CLIENT;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=FALSE"

    case name do
      name when is_binary(name) and name != "" ->
        "ATTENDEE;#{params};CN=#{escape_text(name)}:mailto:#{email}"

      _missing ->
        "ATTENDEE;#{params}:mailto:#{email}"
    end
  end

  defp attendee_property(email, name, :contact) do
    case name do
      name when is_binary(name) and name != "" -> "CONTACT:#{escape_text(name)} <#{email}>"
      _missing -> "CONTACT:#{email}"
    end
  end

  # We still emit `ORGANIZER` on every event so scheduling-aware servers
  # don't inject one of their own at calendar-owner level (which would
  # itself fire iTIP). The `SCHEDULE-AGENT=CLIENT` parameter is kept as
  # defence-in-depth for servers that honour RFC 6638 §7.1 even though
  # Zimbra silently strips it (see issue #41).
  @spec build_organizer_line(map()) :: String.t() | nil
  def build_organizer_line(%{organizer_email: email} = event)
      when is_binary(email) and email != "" do
    case Map.get(event, :organizer_name) do
      name when is_binary(name) and name != "" ->
        "ORGANIZER;SCHEDULE-AGENT=CLIENT;CN=#{escape_text(name)}:mailto:#{sanitize_ical_value(email)}"

      _missing ->
        "ORGANIZER;SCHEDULE-AGENT=CLIENT:mailto:#{sanitize_ical_value(email)}"
    end
  end

  def build_organizer_line(_event), do: nil
end
