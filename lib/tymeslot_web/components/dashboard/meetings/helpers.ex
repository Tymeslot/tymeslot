defmodule TymeslotWeb.Components.Dashboard.Meetings.Helpers do
  @moduledoc """
  Helpers for meeting display and policy checks in the dashboard.
  """

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Utils.DateTimeUtils
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias TymeslotWeb.Helpers.LocaleFormat

  # Status helpers
  @spec past_meeting?(Ecto.Schema.t()) :: boolean()
  def past_meeting?(meeting) do
    DateTime.compare(meeting.end_time, DateTime.utc_now()) == :lt
  end

  # Policy helpers (surface booleans)
  @spec can_cancel?(Ecto.Schema.t()) :: boolean()
  def can_cancel?(meeting) do
    case Policy.can_cancel_meeting?(meeting) do
      :ok -> true
      {:error, _reason} -> false
    end
  end

  @spec can_reschedule?(Ecto.Schema.t()) :: boolean()
  def can_reschedule?(meeting) do
    case Policy.can_reschedule_meeting?(meeting) do
      :ok -> true
      {:error, _reason} -> false
    end
  end

  # Timezone + formatting helpers
  @spec get_meeting_timezone(Ecto.Schema.t() | nil, Ecto.Schema.t() | nil) :: String.t()
  def get_meeting_timezone(nil, _profile), do: "UTC"
  def get_meeting_timezone(_meeting, nil), do: "UTC"

  def get_meeting_timezone(_meeting, profile) do
    # Organizer's timezone for the dashboard view
    (profile && profile.timezone) || "UTC"
  end

  @spec format_meeting_date(Ecto.Schema.t(), String.t()) :: String.t()
  def format_meeting_date(meeting, timezone) do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)
    local_time = DateTimeUtils.convert_to_timezone(meeting.start_time, timezone)
    LocaleFormat.format_date(local_time, locale)
  end

  @doc """
  Formats a meeting's time range for the organiser's dashboard.

  Takes the clock format explicitly rather than defaulting it: the dashboard is
  organiser-facing and must follow their preference, so a call site that has
  not thought about which clock to use should fail to compile rather than
  quietly pick one.
  """
  @spec format_meeting_time(Ecto.Schema.t(), String.t(), String.t()) :: String.t()
  def format_meeting_time(meeting, timezone, time_format) do
    local_start = DateTimeUtils.convert_to_timezone(meeting.start_time, timezone)
    local_end = DateTimeUtils.convert_to_timezone(meeting.end_time, timezone)

    start_time = TimeFormat.format(local_start, time_format)
    end_time = TimeFormat.format(local_end, time_format)
    "#{start_time} - #{end_time}"
  end
end
