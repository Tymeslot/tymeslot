defmodule Tymeslot.Telegram.MessageBuilder do
  @moduledoc """
  Builds formatted Telegram HTML messages for meeting events.
  All user-provided data is HTML-escaped before insertion.
  """

  alias Phoenix.HTML

  @spec build_message(String.t(), %{atom() => term()}) :: String.t()
  def build_message("meeting.created", meeting) do
    String.trim("""
    #{emoji(:calendar)} <b>New Meeting</b>

    <b>#{esc(attendee_name(meeting))}</b> booked <i>#{esc(meeting_title(meeting))}</i>
    #{emoji(:clock)} #{format_time(meeting)}
    #{emoji(:email)} #{esc(meeting.attendee_email)}
    #{video_line(meeting)}\
    #{link_line(meeting)}\
    """)
  end

  def build_message("meeting.cancelled", meeting) do
    String.trim("""
    #{emoji(:cancel)} <b>Meeting Cancelled</b>

    <b>#{esc(attendee_name(meeting))}</b> cancelled <i>#{esc(meeting_title(meeting))}</i>
    #{emoji(:clock)} #{format_time(meeting)}
    #{cancellation_reason(meeting)}\
    #{link_line(meeting)}\
    """)
  end

  def build_message("meeting.rescheduled", meeting) do
    String.trim("""
    #{emoji(:reschedule)} <b>Meeting Rescheduled</b>

    <b>#{esc(attendee_name(meeting))}</b> rescheduled <i>#{esc(meeting_title(meeting))}</i>
    #{emoji(:clock)} #{format_time(meeting)}
    #{emoji(:email)} #{esc(meeting.attendee_email)}
    #{video_line(meeting)}\
    #{link_line(meeting)}\
    """)
  end

  def build_message(event_type, meeting) do
    String.trim("""
    #{emoji(:calendar)} <b>Meeting Update</b>

    <b>#{esc(attendee_name(meeting))}</b> — <i>#{esc(meeting_title(meeting))}</i>
    #{emoji(:clock)} #{format_time(meeting)}
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

  defp format_time(meeting) do
    timezone = meeting.attendee_timezone || "UTC"

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
    end_str = Calendar.strftime(end_time, "%H:%M")

    "#{date}, #{start_str}\u2013#{end_str} (#{esc(timezone)})"
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

  defp link_line(meeting) do
    uid = Map.get(meeting, :uid)

    if uid do
      endpoint_config = Application.get_env(:tymeslot, TymeslotWeb.Endpoint)
      host = System.get_env("PHX_HOST") || get_in(endpoint_config, [:url, :host]) || "localhost"
      scheme = System.get_env("PHX_SCHEME") || get_in(endpoint_config, [:url, :scheme]) || "https"
      "\n\n<a href=\"#{scheme}://#{host}/dashboard/meetings\">View in dashboard</a>"
    else
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
