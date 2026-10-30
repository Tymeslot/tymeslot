defmodule TymeslotWeb.Helpers.MeetingTimeFormat do
  @moduledoc """
  Formats a meeting's start time for the public token-authenticated pages
  (guest RSVP, seat management).

  These pages render for a recipient who has no session, so the string is
  built from the current Gettext locale and an explicit timezone. The caller
  decides both: the seat pages put the participant's stored locale and pass
  their stored timezone, the guest RSVP pages keep the request's locale.
  """

  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Helpers.LocaleFormat

  @doc """
  Renders `meeting.start_time` in `timezone`, suffixed with the zone it is
  shown in. Falls back to the stored UTC time when the zone cannot be
  resolved, so the page still states a time rather than nothing.
  """
  @spec format_when(map(), String.t() | nil) :: String.t()
  def format_when(meeting, timezone) do
    {dt, zone} = DateTimeUtils.shift_or_utc(meeting.start_time, timezone)
    format_datetime(dt) <> " (#{zone})"
  end

  defp format_datetime(dt),
    do: LocaleFormat.format_weekday_datetime(dt, Gettext.get_locale(TymeslotWeb.Gettext))
end
