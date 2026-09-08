defmodule Tymeslot.Notifications.Recipients do
  @moduledoc """
  Determines who should receive notifications and their context.
  Pure functions for recipient determination and notification targeting.
  """

  alias Tymeslot.Meetings
  alias Tymeslot.Profiles

  @typep participant :: %{
           required(:email) => String.t() | nil,
           required(:name) => String.t() | nil,
           required(:timezone) => String.t()
         }

  @doc """
  Determines the recipients for a given notification type and meeting.

  Routing depends on the meeting, not the notification type: every type routes
  the same way today, and the type is accepted for a future channel that needs
  to route differently. A group meeting routes to the organizer only — see
  `recipients_for/2`.
  """
  @spec determine_recipients(term(), atom()) ::
          {:both | :organizer_only,
           %{
             required(:organizer) => participant(),
             required(:attendee) => participant()
           }}
  def determine_recipients(meeting, _notification_type) do
    recipients_for(meeting, base_recipients(meeting))
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

  # A group meeting's row carries no attendee of its own — `attendee_email`,
  # `attendee_name` and `attendee_timezone` are nullable precisely because
  # group attendees live on `meeting_participants`, not on the meeting row.
  # The organizer is still a real recipient; the meeting-row "attendee" is
  # not, so validation must not demand fields that cannot exist. Participants
  # are resolved and emailed downstream via `Meetings.recipients/1`.
  defp recipients_for(meeting, base_recipients) do
    if Meetings.group?(meeting) do
      {:organizer_only, base_recipients}
    else
      {:both, base_recipients}
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
