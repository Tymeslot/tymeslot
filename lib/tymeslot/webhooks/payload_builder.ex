defmodule Tymeslot.Webhooks.PayloadBuilder do
  @moduledoc """
  Builds standardized webhook payloads for different event types.

  Ensures consistent payload structure across all webhook deliveries,
  making it easy for users to parse in their automation tools (n8n, Zapier, etc.).
  """

  alias Tymeslot.Meetings.MeetingSchema

  @doc """
  Builds a webhook payload for a meeting event.
  """
  @spec build_payload(String.t(), MeetingSchema.t(), String.t()) :: %{
          required(:event) => String.t(),
          required(:timestamp) => String.t(),
          required(:webhook_id) => String.t(),
          required(:data) => %{required(:meeting) => term()}
        }
  def build_payload(event_type, meeting, webhook_id) do
    %{
      event: event_type,
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      webhook_id: webhook_id,
      data: %{
        meeting: build_meeting_data(meeting)
      }
    }
  end

  @doc """
  Builds a test payload for connection testing.
  """
  @spec build_test_payload() :: %{
          required(:event) => String.t(),
          required(:timestamp) => String.t(),
          required(:webhook_id) => String.t(),
          required(:data) => %{required(:message) => String.t(), required(:test) => boolean()}
        }
  def build_test_payload do
    %{
      event: "webhook.test",
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      webhook_id: "test",
      data: %{
        message:
          "This is a test webhook from Tymeslot. If you receive this, your webhook is configured correctly!",
        test: true
      }
    }
  end

  # Private functions

  defp build_meeting_data(%MeetingSchema{} = meeting) do
    maybe_add_cancellation_data(
      %{
        id: meeting.id,
        uid: meeting.uid,
        title: meeting.title,
        summary: meeting.summary,
        description: meeting.description,
        start_time: format_datetime(meeting.start_time),
        end_time: format_datetime(meeting.end_time),
        duration: meeting.duration,
        status: meeting.status,
        meeting_type: meeting.meeting_type,
        location: meeting.location,
        organizer: build_organizer_data(meeting),
        attendee: build_attendee_data(meeting),
        guests: build_guests_data(meeting),
        urls: build_urls(meeting),
        video: build_video_data(meeting),
        created_at: format_datetime(meeting.inserted_at),
        updated_at: format_datetime(meeting.updated_at)
      },
      meeting
    )
  end

  defp build_organizer_data(meeting) do
    %{
      name: meeting.organizer_name,
      email: meeting.organizer_email,
      title: meeting.organizer_title,
      user_id: meeting.organizer_user_id
    }
  end

  defp build_attendee_data(meeting) do
    %{
      name: meeting.attendee_name,
      email: meeting.attendee_email,
      phone: meeting.attendee_phone,
      company: meeting.attendee_company,
      timezone: meeting.attendee_timezone,
      message: meeting.attendee_message
    }
  end

  # Guests are read from the loaded association rather than fetched here, so
  # this module stays a pure function of the struct it is handed — which is how
  # its tests build meetings, without a database. `WebhookWorker` loads them.
  # A meeting arriving without the association yields an empty list rather than
  # a crash, and the worker's own test covers the path that must not be empty.
  defp build_guests_data(%MeetingSchema{guests: guests}) when is_list(guests) do
    Enum.map(guests, fn guest ->
      %{
        email: guest.email,
        name: guest.name,
        status: guest.status,
        responded_at: format_datetime(guest.responded_at)
      }
    end)
  end

  defp build_guests_data(_meeting), do: []

  defp build_urls(meeting) do
    %{
      view: meeting.view_url,
      reschedule: meeting.reschedule_url,
      cancel: meeting.cancel_url,
      meeting: meeting.meeting_url
    }
  end

  defp build_video_data(meeting) do
    if meeting.video_room_enabled do
      %{
        enabled: true,
        room_id: meeting.video_room_id,
        organizer_url: meeting.organizer_video_url,
        attendee_url: meeting.attendee_video_url,
        created_at: format_datetime(meeting.video_room_created_at),
        expires_at: format_datetime(meeting.video_room_expires_at)
      }
    else
      %{enabled: false}
    end
  end

  defp maybe_add_cancellation_data(data, %MeetingSchema{status: "cancelled"} = meeting) do
    Map.put(data, :cancellation, %{
      cancelled_at: format_datetime(meeting.cancelled_at),
      reason: meeting.cancellation_reason
    })
  end

  defp maybe_add_cancellation_data(data, _meeting), do: data

  defp format_datetime(nil), do: nil

  defp format_datetime(%DateTime{} = dt) do
    DateTime.to_iso8601(dt)
  end
end
