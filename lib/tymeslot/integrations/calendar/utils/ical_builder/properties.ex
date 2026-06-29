defmodule Tymeslot.Integrations.Calendar.ICalBuilder.Properties do
  @moduledoc """
  VEVENT property-line serialisers for the canonical event shape.

  Each public function maps one field of the canonical event map to its RFC
  5545 / RFC 7986 property line — or `nil` when the field is absent — for
  assembly by `ICalBuilder.build_simple_event/2`. `build_dtstart/1` and
  `build_dtend/1` are shared with the legacy `ICalBuilder.build_event/1` path.
  """

  import Tymeslot.Integrations.Calendar.ICalBuilder.Format,
    only: [
      format_date: 1,
      format_datetime: 1,
      format_naive_datetime: 1,
      escape_text: 1,
      sanitize_ical_value: 1
    ]

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
    case attachment[:content_type] || attachment["content_type"] do
      mime when is_binary(mime) and mime != "" ->
        "ATTACH;FMTTYPE=#{mime}:#{sanitize_ical_value(url)}"

      _missing ->
        "ATTACH:#{sanitize_ical_value(url)}"
    end
  end

  defp attachment_line(_other), do: nil

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

  # Issue #41: Zimbra (and likely other CalDAV servers) silently strips
  # `SCHEDULE-AGENT` from incoming events and runs iTIP scheduling for any
  # event that carries an `ATTENDEE` block — re-emailing the attendee on top
  # of Tymeslot's own notification. The only reliable way to keep CalDAV
  # servers from auto-scheduling is to not advertise an attendee at all.
  #
  # We emit `CONTACT` instead (RFC 5545 §3.8.4.2), which carries the same
  # name/email but is not part of the iTIP scheduling model. The attendee
  # identity is also folded into the event DESCRIPTION (see
  # `CalendarEventBuilder.build_event_description/1`) so it remains visible
  # in calendar clients that don't render CONTACT.
  @spec build_attendee_lines(map()) :: String.t() | nil
  def build_attendee_lines(%{attendees: attendees})
      when is_list(attendees) and attendees != [] do
    attendees
    |> Enum.map(&format_attendee/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\r\n")
  end

  def build_attendee_lines(%{attendee_email: email} = event) when is_binary(email) do
    name = Map.get(event, :attendee_name)
    format_attendee(%{email: email, name: name})
  end

  def build_attendee_lines(_event), do: nil

  defp format_attendee(%{"email" => email} = a),
    do: format_attendee(%{email: email, name: a["name"]})

  defp format_attendee(%{email: email} = a) when is_binary(email) and email != "" do
    case a[:name] do
      name when is_binary(name) and name != "" ->
        "CONTACT:#{escape_text(name)} <#{sanitize_ical_value(email)}>"

      _missing ->
        "CONTACT:#{sanitize_ical_value(email)}"
    end
  end

  defp format_attendee(email) when is_binary(email) and email != "" do
    "CONTACT:#{sanitize_ical_value(email)}"
  end

  defp format_attendee(_other), do: nil

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
