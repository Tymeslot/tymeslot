defmodule Tymeslot.Notifications.Recipients do
  @moduledoc """
  Whether a meeting carries what its emails need (`validate/2`), and the
  timezones its organiser and attendee read times in.
  """

  require Logger

  alias Tymeslot.Emails.HostClock
  alias Tymeslot.Meetings

  @doc """
  Whether `meeting` carries what its emails need, checked on the meeting's
  own fields, with no lookups.

  `:recipients` (cancellation) needs the organiser's name and email and, for
  a solo meeting, the attendee's. `:booking` (confirmation, reminders,
  reschedule) also needs the calendar event's `calendar_uid` and the start
  time. A group meeting's row carries no attendee of its own (its people are
  its participants, emailed per seat), so its attendee fields are not asked
  for. A field is missing when it is nil or false, as before.
  """
  @spec validate(map(), :booking | :recipients) :: :ok | {:error, String.t()}
  def validate(meeting, scope \\ :booking) do
    case Enum.reject(required_fields(meeting, scope), &Map.get(meeting, &1)) do
      [] -> :ok
      missing -> {:error, "Missing meeting fields: #{Enum.join(missing, ", ")}"}
    end
  end

  defp required_fields(meeting, :booking),
    do: [:calendar_uid, :start_time | required_fields(meeting, :recipients)]

  defp required_fields(meeting, :recipients) do
    if Meetings.group?(meeting),
      do: [:organizer_name, :organizer_email],
      else: [:organizer_name, :organizer_email, :attendee_name, :attendee_email]
  end

  @doc """
  Gets the organizer's timezone from their profile.
  Requires the meeting to have organizer_user_id set.
  """
  @spec get_organizer_timezone(term()) :: String.t()
  def get_organizer_timezone(%{organizer_user_id: nil} = meeting) do
    Logger.error("Missing organizer_user_id for meeting; using default timezone",
      meeting_id: Map.get(meeting, :id)
    )

    HostClock.timezone(meeting)
  end

  def get_organizer_timezone(meeting), do: HostClock.timezone(meeting)

  @doc """
  Gets the attendee's timezone from the meeting record.
  The attendee_timezone should always be populated during booking creation.
  """
  @spec get_attendee_timezone(term()) :: String.t()
  # A group meeting's row never carries an attendee (its people are its
  # participants), so a missing timezone there is the design, not a defect
  # worth a warning on every booking.
  def get_attendee_timezone(%{attendee_timezone: nil, capacity: capacity} = meeting)
      when is_integer(capacity) and capacity > 1,
      do: get_organizer_timezone(meeting)

  def get_attendee_timezone(meeting) do
    # This should always be set, but add defensive logging
    case meeting.attendee_timezone do
      nil ->
        require Logger

        Logger.warning(
          "Missing attendee_timezone for meeting; using organizer timezone as emergency fallback",
          meeting_id: Map.get(meeting, :id)
        )

        get_organizer_timezone(meeting)

      timezone ->
        timezone
    end
  end
end
