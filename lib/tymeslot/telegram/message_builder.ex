defmodule Tymeslot.Telegram.MessageBuilder do
  @moduledoc """
  Builds formatted Telegram HTML messages for meeting events.
  All user-provided data is HTML-escaped before insertion.

  Times are rendered in the timezone the caller passes, which is the
  organiser's: these messages go to the organiser's own chat, so the attendee's
  timezone would leave them converting every booking by hand.
  """

  alias Phoenix.HTML
  alias Tymeslot.Bookings.MeetingLinks
  alias Tymeslot.Meetings.AttendeeName
  alias Tymeslot.Meetings.HostManaged
  alias Tymeslot.Notifications.BookingDetails
  alias Tymeslot.Notifications.EventTypes

  # Matched by name rather than wire literal; any other name (a job queued
  # before an event was renamed) falls through to the generic clause.
  @created EventTypes.to_event_type(:meeting_created)
  @cancelled EventTypes.to_event_type(:meeting_cancelled)
  @rescheduled EventTypes.to_event_type(:meeting_rescheduled)
  @requested EventTypes.to_event_type(:meeting_requested)
  @declined EventTypes.to_event_type(:meeting_declined)
  @request_expired EventTypes.to_event_type(:meeting_request_expired)

  @spec build_message(String.t(), %{atom() => term()}, String.t()) :: String.t()
  def build_message(@created, meeting, timezone) do
    String.trim("""
    #{emoji(:calendar)} <b>New Meeting</b>

    #{summary_line(meeting, "booked", "You arranged")}
    #{emoji(:clock)} #{format_time(meeting, timezone)}
    #{email_line(meeting)}\
    #{video_line(meeting)}\
    #{details_block(meeting)}\
    #{link_line(meeting)}\
    """)
  end

  def build_message(@cancelled, meeting, timezone) do
    String.trim("""
    #{emoji(:cancel)} <b>Meeting Cancelled</b>

    #{summary_line(meeting, "cancelled", "Cancelled")}
    #{emoji(:clock)} #{format_time(meeting, timezone)}
    #{cancellation_reason(meeting)}\
    #{link_line(meeting)}\
    """)
  end

  def build_message(@rescheduled, meeting, timezone) do
    String.trim("""
    #{emoji(:reschedule)} <b>Meeting Rescheduled</b>

    #{summary_line(meeting, "rescheduled", "Moved")}
    #{emoji(:clock)} #{format_time(meeting, timezone)}
    #{email_line(meeting)}\
    #{video_line(meeting)}\
    #{details_block(meeting)}\
    #{link_line(meeting)}\
    """)
  end

  def build_message(@requested, meeting, timezone) do
    String.trim("""
    #{emoji(:calendar)} <b>New Booking Request</b>

    <b>#{esc(attendee_name(meeting))}</b> asked for <i>#{esc(meeting_title(meeting))}</i>
    #{emoji(:clock)} #{format_time(meeting, timezone)}
    #{email_line(meeting)}\
    #{deadline_line(meeting, timezone)}\
    #{details_block(meeting)}\
    #{link_line(meeting)}\
    """)
  end

  def build_message(@declined, meeting, timezone) do
    String.trim("""
    #{emoji(:cancel)} <b>Booking Request Declined</b>

    <b>#{esc(attendee_name(meeting))}</b> — <i>#{esc(meeting_title(meeting))}</i>
    #{emoji(:clock)} #{format_time(meeting, timezone)}
    #{decline_line(meeting)}\
    #{link_line(meeting)}\
    """)
  end

  def build_message(@request_expired, meeting, timezone) do
    String.trim("""
    #{emoji(:cancel)} <b>Booking Request Expired</b>

    <b>#{esc(attendee_name(meeting))}</b> — <i>#{esc(meeting_title(meeting))}</i>
    #{emoji(:clock)} #{format_time(meeting, timezone)}
    Nobody responded before the deadline, so the slot was released.
    #{link_line(meeting)}\
    """)
  end

  def build_message(event_type, meeting, timezone) do
    String.trim("""
    #{emoji(:calendar)} <b>Meeting Update</b>

    <b>#{esc(attendee_name(meeting))}</b> — <i>#{esc(meeting_title(meeting))}</i>
    #{emoji(:clock)} #{format_time(meeting, timezone)}
    #{email_line(meeting)}\
    Event: #{esc(event_type)}\
    #{link_line(meeting)}\
    """)
  end

  @spec build_test_message() :: String.t()
  def build_test_message do
    "#{emoji(:check)} <b>Tymeslot Test</b>\n\nThis is a test message from your Tymeslot integration. If you see this, notifications are working correctly!"
  end

  # Private helpers

  defp esc(nil), do: ""

  defp esc(text) when is_binary(text) do
    text
    |> HTML.html_escape()
    |> HTML.safe_to_string()
  end

  # The attendee's name, or their address where they have no name of their
  # own (a meeting the host manages names its first guest by their address).
  defp attendee_name(meeting) do
    AttendeeName.display_name(meeting) || meeting.attendee_email
  end

  # Who did what. A meeting the host manages is arranged, moved and cancelled
  # by the host alone, so the guest in its attendee fields is never the one
  # who acted: `host_verb` leads instead, and the guest is who it is with.
  defp summary_line(meeting, attendee_verb, host_verb) do
    who = esc(attendee_name(meeting))
    title = esc(meeting_title(meeting))

    if HostManaged.managed?(meeting),
      do: "#{host_verb} <i>#{title}</i> with <b>#{who}</b>",
      else: "<b>#{who}</b> #{attendee_verb} <i>#{title}</i>"
  end

  # The address on a line of its own, unless the name line already shows it.
  defp email_line(meeting) do
    case {AttendeeName.display_name(meeting), meeting.attendee_email} do
      {nil, _email} -> ""
      {_name, email} -> "#{emoji(:email)} #{esc(email)}\n"
    end
  end

  defp meeting_title(meeting) do
    cond do
      Map.has_key?(meeting, :event_type) and
        is_struct(meeting.event_type) and
          not is_struct(meeting.event_type, Ecto.Association.NotLoaded) ->
        Map.get(meeting.event_type, :name, "Meeting")

      Map.has_key?(meeting, :event_type_name) ->
        meeting.event_type_name || "Meeting"

      true ->
        "Meeting"
    end
  end

  defp format_time(meeting, timezone) do
    start_time =
      case DateTime.shift_zone(meeting.start_time, timezone) do
        {:ok, dt} -> dt
        _error -> meeting.start_time
      end

    end_time =
      case DateTime.shift_zone(meeting.end_time, timezone) do
        {:ok, dt} -> dt
        _error -> meeting.end_time
      end

    date = Calendar.strftime(start_time, "%a %d %b %Y")
    start_str = Calendar.strftime(start_time, "%H:%M")

    if DateTime.to_date(end_time) == DateTime.to_date(start_time) do
      "#{date}, #{start_str}\u2013#{Calendar.strftime(end_time, "%H:%M")} (#{esc(timezone)})"
    else
      "#{date}, #{start_str} \u2013 #{Calendar.strftime(end_time, "%a %d %b %H:%M")} (#{esc(timezone)})"
    end
  end

  defp video_line(meeting) do
    video_url = Map.get(meeting, :video_room_url) || Map.get(meeting, :video_link)

    if video_url && safe_url?(video_url) do
      "\n#{emoji(:video)} <a href=\"#{esc(video_url)}\">Join video call</a>"
    else
      ""
    end
  end

  defp safe_url?(url) when is_binary(url) do
    String.starts_with?(url, "https://") or String.starts_with?(url, "http://")
  end

  defp safe_url?(_url), do: false

  defp cancellation_reason(meeting) do
    reason = Map.get(meeting, :cancellation_reason)

    if reason && String.trim(reason) != "" do
      "\n#{emoji(:note)} Reason: #{esc(reason)}"
    else
      ""
    end
  end

  defp deadline_line(meeting, timezone) do
    case Map.get(meeting, :approval_deadline_at) do
      %DateTime{} = deadline ->
        local =
          case DateTime.shift_zone(deadline, timezone) do
            {:ok, dt} -> dt
            _error -> deadline
          end

        "\n#{emoji(:note)} Respond by #{Calendar.strftime(local, "%a %d %b %Y, %H:%M")}"

      _none ->
        ""
    end
  end

  defp decline_line(meeting) do
    case Map.get(meeting, :decline_reason) do
      reason when is_binary(reason) and reason != "" -> "\n#{emoji(:note)} Reason: #{esc(reason)}"
      _none -> ""
    end
  end

  # What the booker told the organiser: contact details, where to meet, their
  # notes and their answers, each block led by a blank line.
  defp details_block(meeting) do
    details = BookingDetails.from_meeting(meeting)

    [contact_lines(details), note_lines(details), answer_lines(details)]
    |> Enum.reject(&(&1 == []))
    |> Enum.map_join(fn lines -> "\n\n" <> Enum.join(lines, "\n") end)
  end

  defp contact_lines(details) do
    for {key, icon} <- [location: :location, phone: :phone, company: :company],
        value = details[key],
        do: "#{emoji(icon)} #{esc(value)}"
  end

  defp note_lines(%{note: nil}), do: []
  defp note_lines(%{note: note}), do: ["#{emoji(:note)} #{esc(note)}"]

  defp answer_lines(%{answers: answers, more_answers: more}) do
    lines = Enum.map(answers, fn {label, value} -> "<b>#{esc(label)}</b>: #{esc(value)}" end)

    case more do
      0 -> lines
      1 -> lines ++ ["<i>1 more answer in the dashboard</i>"]
      n -> lines ++ ["<i>#{n} more answers in the dashboard</i>"]
    end
  end

  defp link_line(meeting) do
    case Map.get(meeting, :id) do
      id when is_binary(id) ->
        "\n\n<a href=\"#{esc(MeetingLinks.host_view_url(id))}\">View in dashboard</a>"

      _none ->
        ""
    end
  end

  defp emoji(:calendar), do: "\u{1F4C5}"
  defp emoji(:clock), do: "\u{1F550}"
  defp emoji(:email), do: "\u{1F4E7}"
  defp emoji(:cancel), do: "\u274C"
  defp emoji(:reschedule), do: "\u{1F504}"
  defp emoji(:video), do: "\u{1F4F9}"
  defp emoji(:note), do: "\u{1F4DD}"
  defp emoji(:check), do: "\u2705"
  defp emoji(:location), do: "\u{1F4CD}"
  defp emoji(:phone), do: "\u{1F4DE}"
  defp emoji(:company), do: "\u{1F3E2}"
end
