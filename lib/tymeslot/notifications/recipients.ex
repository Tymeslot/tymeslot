defmodule Tymeslot.Notifications.Recipients do
  @moduledoc """
  Determines who should receive notifications and their context.
  Pure functions for recipient determination and notification targeting.
  """

  alias Tymeslot.Profiles

  @typep participant :: %{
           required(:email) => String.t() | nil,
           required(:name) => String.t() | nil,
           required(:timezone) => String.t()
         }

  @typep notification_context :: %{
           required(:meeting_id) => term(),
           required(:meeting_uid) => String.t() | nil,
           required(:organizer_email) => String.t() | nil,
           required(:attendee_email) => String.t() | nil,
           required(:meeting_status) => atom() | nil,
           required(:has_video_room) => boolean() | nil,
           required(:meeting_start) => DateTime.t() | nil,
           required(:meeting_end) => DateTime.t() | nil
         }

  @doc """
  Determines the recipients for a given notification type and meeting.

  Every notification type currently routes to both participants; the type is
  accepted for a future channel that needs to route differently, not used
  today.
  """
  @spec determine_recipients(term(), atom()) ::
          {:both,
           %{
             required(:organizer) => participant(),
             required(:attendee) => participant()
           }}
  def determine_recipients(meeting, _notification_type) do
    {:both, base_recipients(meeting)}
  end

  defp base_recipients(meeting) do
    %{
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
  end

  # Meeting-level context shared by both recipient variants of
  # `build_recipient_context/2`, which is its only caller.
  @spec notification_context(term()) :: notification_context()
  defp notification_context(meeting) do
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
  Gets the organizer's timezone from their profile.
  Requires the meeting to have organizer_user_id set.
  """
  @spec get_organizer_timezone(term()) :: String.t()
  def get_organizer_timezone(meeting) do
    case meeting.organizer_user_id do
      nil ->
        require Logger

        Logger.error("Missing organizer_user_id for meeting; using default timezone",
          meeting_uid: meeting.uid
        )

        Profiles.get_default_timezone()

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
          "Missing attendee_timezone for meeting; using organizer timezone as emergency fallback",
          meeting_uid: meeting.uid
        )

        get_organizer_timezone(meeting)

      timezone ->
        timezone
    end
  end

  @doc """
  Builds recipient-specific context for email templates.
  """
  @spec build_recipient_context(term(), atom()) :: %{
          required(:meeting_id) => term(),
          required(:meeting_uid) => String.t() | nil,
          required(:organizer_email) => String.t() | nil,
          required(:attendee_email) => String.t() | nil,
          required(:meeting_status) => atom() | nil,
          required(:has_video_room) => boolean() | nil,
          required(:meeting_start) => DateTime.t() | nil,
          required(:meeting_end) => DateTime.t() | nil,
          required(:recipient_name) => String.t() | nil,
          required(:recipient_email) => String.t() | nil,
          required(:recipient_timezone) => String.t(),
          required(:recipient_type) => atom()
        }
  def build_recipient_context(meeting, recipient_type) do
    base_context = notification_context(meeting)

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

      _invalid_structure ->
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
