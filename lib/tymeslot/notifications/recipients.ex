defmodule Tymeslot.Notifications.Recipients do
  @moduledoc """
  Determines who should receive notifications and their context.
  Pure functions for recipient determination and notification targeting.
  """

  alias Tymeslot.Profiles

  @doc """
  Determines the recipients for a given notification type and meeting.
  """
  @spec determine_recipients(term(), atom()) :: {atom(), map()}
  def determine_recipients(meeting, notification_type) do
    base_recipients = %{
      organizer: %{
        email: meeting.organizer_email,
        name: meeting.organizer_name,
        timezone: get_organizer_timezone(meeting)
      },
      attendee: %{
        email: meeting.attendee_email,
        name: meeting.attendee_name,
        timezone: meeting.attendee_timezone || get_organizer_timezone(meeting)
      }
    }

    case notification_type do
      :confirmation ->
        {:both, base_recipients}

      :reminder ->
        {:both, base_recipients}

      :cancellation ->
        {:both, base_recipients}

      :reschedule ->
        {:both, base_recipients}

      :video_room_created ->
        {:both, base_recipients}

      :video_room_failed ->
        {:organizer_only, base_recipients}

      _ ->
        {:both, base_recipients}
    end
  end

  @doc """
  Gets the notification context for a meeting.
  """
  @spec get_notification_context(term()) :: map()
  def get_notification_context(meeting) do
    %{
      meeting_id: meeting.id,
      meeting_uid: meeting.uid,
      organizer_email: meeting.organizer_email,
      attendee_email: meeting.attendee_email,
      meeting_status: meeting.status,
      has_video_room: meeting.video_room_enabled,
      meeting_start: meeting.start_time,
      meeting_end: meeting.end_time
    }
  end

  @doc """
  Determines if a recipient should receive a specific notification.
  """
  @spec should_receive_notification?(atom(), atom(), term()) :: boolean()
  def should_receive_notification?(recipient_type, notification_type, _meeting) do
    case {recipient_type, notification_type} do
      {:organizer, :video_room_failed} -> true
      {:organizer, _} -> true
      {:attendee, :video_room_failed} -> false
      {:attendee, _} -> true
      _ -> false
    end
  end

  @doc """
  Gets the organizer's timezone from their profile.
  Requires the meeting to have organizer_user_id set.
  """
  @spec get_organizer_timezone(term()) :: String.t()
  def get_organizer_timezone(meeting) do
    case meeting.organizer_user_id do
      nil ->
        require Logger

        Logger.error(
          "Missing organizer_user_id for meeting #{meeting.uid}, using default timezone"
        )

        "Europe/Kyiv"

      user_id ->
        Profiles.get_user_timezone(user_id)
    end
  end

  @doc """
  Gets the attendee's timezone from the meeting record.
  The attendee_timezone should always be populated during booking creation.
  """
  @spec get_attendee_timezone(term()) :: String.t()
  def get_attendee_timezone(meeting) do
    # This should always be set, but add defensive logging
    case meeting.attendee_timezone do
      nil ->
        require Logger

        Logger.warning(
          "Missing attendee_timezone for meeting #{meeting.uid}, using organizer timezone as emergency fallback"
        )

        get_organizer_timezone(meeting)

      timezone ->
        timezone
    end
  end

  @doc """
  Builds recipient-specific context for email templates.
  """
  @spec build_recipient_context(term(), atom()) :: map()
  def build_recipient_context(meeting, recipient_type) do
    base_context = get_notification_context(meeting)

    case recipient_type do
      :organizer ->
        Map.merge(base_context, %{
          recipient_name: meeting.organizer_name,
          recipient_email: meeting.organizer_email,
          recipient_timezone: get_organizer_timezone(meeting),
          recipient_type: :organizer
        })

      :attendee ->
        Map.merge(base_context, %{
          recipient_name: meeting.attendee_name,
          recipient_email: meeting.attendee_email,
          recipient_timezone: get_attendee_timezone(meeting),
          recipient_type: :attendee
        })
    end
  end

  @doc """
  Validates that recipient information is complete.
  """
  @spec validate_recipients(term()) :: :ok | {:error, String.t()}
  def validate_recipients(recipients) do
    case recipients do
      {:both, %{organizer: organizer, attendee: attendee}} ->
        with :ok <- validate_recipient(organizer, :organizer) do
          validate_recipient(attendee, :attendee)
        end

      {:organizer_only, %{organizer: organizer}} ->
        validate_recipient(organizer, :organizer)

      {:attendee_only, %{attendee: attendee}} ->
        validate_recipient(attendee, :attendee)

      _ ->
        {:error, "Invalid recipient structure"}
    end
  end

  # Private functions

  defp validate_recipient(recipient, type) do
    required_fields = [:email, :name, :timezone]

    missing_fields =
      Enum.reject(required_fields, fn field ->
        Map.has_key?(recipient, field) and recipient[field]
      end)

    case missing_fields do
      [] -> :ok
      fields -> {:error, "Missing #{type} fields: #{Enum.join(fields, ", ")}"}
    end
  end
end
