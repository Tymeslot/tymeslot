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

    <b>#{esc(attendee_name(meeting))}</b> booked <i>#{esc(meeting_title(meeting))}</i>
    #{emoji(:clock)} #{format_time(meeting, timezone)}
    #{emoji(:email)} #{esc(meeting.attendee_email)}
    #{video_line(meeting)}\
    #{link_line(meeting)}\
    """)
  end

  def build_message(@cancelled, meeting, timezone) do
    String.trim("""
    #{emoji(:cancel)} <b>Meeting Cancelled</b>

    <b>#{esc(attendee_name(meeting))}</b> cancelled <i>#{esc(meeting_title(meeting))}</i>
    #{emoji(:clock)} #{format_time(meeting, timezone)}
    #{cancellation_reason(meeting)}\
    #{link_line(meeting)}\
    """)
  end

  def build_message(@rescheduled, meeting, timezone) do
    String.trim("""
    #{emoji(:reschedule)} <b>Meeting Rescheduled</b>

    <b>#{esc(attendee_name(meeting))}</b> rescheduled <i>#{esc(meeting_title(meeting))}</i>
    #{emoji(:clock)} #{format_time(meeting, timezone)}
    #{emoji(:email)} #{esc(meeting.attendee_email)}
    #{video_line(meeting)}\
    #{link_line(meeting)}\
    """)
  end

  def build_message(@requested, meeting, timezone) do
    String.trim("""
    #{emoji(:calendar)} <b>New Booking Request</b>

    <b>#{esc(attendee_name(meeting))}</b> asked for <i>#{esc(meeting_title(meeting))}</i>
    #{emoji(:clock)} #{format_time(meeting, timezone)}
    #{emoji(:email)} #{esc(meeting.attendee_email)}
    #{deadline_line(meeting, timezone)}\
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
    #{emoji(:email)} #{esc(meeting.attendee_email)}
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

  defp attendee_name(meeting) do
    meeting.attendee_name || meeting.attendee_email
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
end
