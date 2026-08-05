defmodule Tymeslot.Emails.Shared.TimezoneHelper do
  @moduledoc """
  Helper functions for timezone conversions in email templates.
  """

  alias Tymeslot.Utils.DateTimeUtils
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat

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

  This renders the organiser's own clock, so it follows the clock they chose
  rather than a hardcoded 12-hour one.
  """
  @spec format_time_owner_tz(%{
          required(:start_time) => DateTime.t(),
          optional(:start_time_owner_tz) => DateTime.t() | nil,
          optional(:organizer_time_format) => String.t() | nil,
          optional(atom()) => term()
        }) :: String.t()
  def format_time_owner_tz(appointment_details) do
    time_format = Map.get(appointment_details, :organizer_time_format)

    start_time =
      Map.get(appointment_details, :start_time_owner_tz) || appointment_details.start_time

    TimeFormat.format(start_time, time_format)
  end
end
