defmodule Tymeslot.Slack.MessageBuilder do
  @moduledoc """
  Builds Slack Block Kit JSON payloads for each notification event.

  All user-provided strings are escaped for Slack mrkdwn (`&`, `<`, `>`).
  Cancellation reasons are truncated to a safe length to stay within Slack's
  3000-char-per-text-block limit.

  Block Kit reference: https://api.slack.com/block-kit
  """

  alias Tymeslot.Utils.UrlBuilder

  @max_reason_length 500

  @doc "Builds the blocks list for a given event and meeting."
  @spec build_blocks(String.t(), map()) :: [map()]
  def build_blocks("meeting.created", meeting) do
    base = [
      header("New booking"),
      section_summary(meeting),
      divider(),
      section_details(meeting)
    ]

    append_actions(base, meeting)
  end

  def build_blocks("meeting.cancelled", meeting) do
    [
      header("Booking cancelled"),
      section_summary(meeting),
      divider(),
      section_cancellation(meeting)
    ]
  end

  def build_blocks("meeting.rescheduled", meeting) do
    base = [
      header("Booking rescheduled"),
      section_summary(meeting),
      divider(),
      section_reschedule(meeting)
    ]

    append_actions(base, meeting)
  end

  def build_blocks(event_type, meeting) do
    base = [
      header("Meeting update"),
      section_summary(meeting),
      section_text("Event: `#{escape(to_string(event_type))}`")
    ]

    append_actions(base, meeting)
  end

  @doc "Builds the blocks list used by the 'Send test message' button."
  @spec build_test_blocks() :: [map()]
  def build_test_blocks do
    [
      header("Tymeslot test message"),
      section_text(
        "If you can see this, your Slack integration is configured correctly. " <>
          "You'll start receiving notifications when meetings are booked, " <>
          "cancelled, or rescheduled."
      )
    ]
  end

  # ============================================================================
  # Block helpers
  # ============================================================================

  defp header(text) do
    %{
      "type" => "header",
      "text" => %{"type" => "plain_text", "text" => text, "emoji" => true}
    }
  end

  defp divider, do: %{"type" => "divider"}

  defp section_text(text) do
    %{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => text}}
  end

  defp section_summary(meeting) do
    text =
      "*#{escape(meeting_title(meeting))}*\n" <>
        "With #{escape(attendee_name(meeting))} (#{escape(meeting.attendee_email || "no email")})"

    section_text(text)
  end

  defp section_details(meeting) do
    fields = [
      mrkdwn_field("*When*", format_time(meeting)),
      mrkdwn_field("*Duration*", "#{duration_minutes(meeting)} min")
    ]

    %{"type" => "section", "fields" => fields}
  end

  defp section_cancellation(meeting) do
    reason = cancellation_reason(meeting)
    section_text("Cancelled.\n>#{escape(reason)}")
  end

  defp cancellation_reason(meeting) do
    case Map.get(meeting, :cancellation_reason) do
      nil -> "No reason given"
      "" -> "No reason given"
      text -> truncate(text, @max_reason_length)
    end
  end

  defp section_reschedule(meeting) do
    section_text("New time: *#{format_time(meeting)}*")
  end

  defp append_actions(blocks, meeting) do
    case meeting_url(meeting) do
      nil ->
        blocks

      url ->
        blocks ++
          [
            %{
              "type" => "actions",
              "elements" => [
                %{
                  "type" => "button",
                  "text" => %{
                    "type" => "plain_text",
                    "text" => "Open in Tymeslot",
                    "emoji" => true
                  },
                  "url" => url,
                  "style" => "primary"
                }
              ]
            }
          ]
    end
  end

  defp mrkdwn_field(label, value) do
    %{"type" => "mrkdwn", "text" => "#{label}\n#{value}"}
  end

  # ============================================================================
  # Formatters — kept consistent with Tymeslot.Telegram.MessageBuilder so the
  # date/time wording matches across channels.
  # ============================================================================

  defp attendee_name(meeting) do
    meeting.attendee_name || meeting.attendee_email || "guest"
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
        Map.get(meeting, :title) || "Meeting"
    end
  end

  defp format_time(meeting) do
    timezone = Map.get(meeting, :attendee_timezone) || "UTC"

    start_time = shift_zone(meeting.start_time, timezone)
    end_time = shift_zone(meeting.end_time, timezone)

    date = Calendar.strftime(start_time, "%a %d %b %Y")
    start_str = Calendar.strftime(start_time, "%H:%M")
    end_str = Calendar.strftime(end_time, "%H:%M")

    "#{date}, #{start_str}–#{end_str} (#{timezone})"
  end

  defp shift_zone(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> shifted
      _error -> datetime
    end
  end

  defp duration_minutes(%{start_time: s, end_time: e}) do
    div(DateTime.diff(e, s, :second), 60)
  end

  defp meeting_url(meeting) do
    case Map.get(meeting, :uid) do
      nil -> nil
      _uid -> UrlBuilder.build_url("/dashboard/meetings")
    end
  end

  # Slack mrkdwn escape: &, <, > must be escaped.
  defp escape(nil), do: ""

  defp escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape(other), do: other |> to_string() |> escape()

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end
end
