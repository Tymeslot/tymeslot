defmodule Tymeslot.Emails.Shared.TimezoneHelper do
  @moduledoc """
  Helper functions for timezone conversions in email templates.
  """

  alias Tymeslot.Utils.DateTimeUtils

  @doc """
  Converts a datetime to the specified timezone.
  Returns the original datetime if conversion fails.
  """
  @spec convert_to_timezone(DateTime.t(), String.t()) :: DateTime.t()
  def convert_to_timezone(datetime, timezone) do
    DateTimeUtils.convert_to_timezone(datetime, timezone)
  end

  @doc """
  Converts meeting time to attendee's timezone if available.
  Falls back to the original start_time if attendee_timezone is not set or conversion fails.
  """
  @spec convert_to_attendee_timezone(%{
          required(:start_time) => DateTime.t(),
          optional(:attendee_timezone) => String.t() | nil,
          optional(atom()) => term()
        }) :: DateTime.t()
  def convert_to_attendee_timezone(meeting) do
    if meeting.attendee_timezone do
      convert_to_timezone(meeting.start_time, meeting.attendee_timezone)
    else
      meeting.start_time
    end
  end

  @doc """
  Formats time for owner timezone display.
  Uses owner timezone time if available, otherwise falls back to start_time.
  """
  @spec format_time_owner_tz(%{
          required(:start_time) => DateTime.t(),
          optional(:start_time_owner_tz) => DateTime.t() | nil,
          optional(atom()) => term()
        }) :: String.t()
  def format_time_owner_tz(appointment_details) do
    if Map.get(appointment_details, :start_time_owner_tz) do
      Calendar.strftime(appointment_details.start_time_owner_tz, "%I:%M %p")
    else
      Calendar.strftime(appointment_details.start_time, "%I:%M %p")
    end
  end
end
