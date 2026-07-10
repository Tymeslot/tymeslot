defmodule TymeslotWeb.Components.Dashboard.Meetings.Helpers do
  @moduledoc """
  Helpers for meeting display and policy checks in the dashboard.
  """

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Helpers.LocaleFormat

  # Status helpers
  @spec past_meeting?(Ecto.Schema.t()) :: boolean()
  def past_meeting?(meeting) do
    DateTime.compare(meeting.end_time, DateTime.utc_now()) == :lt
  end

  # Policy helpers (surface booleans and tooltips)
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

  @spec action_tooltip(Ecto.Schema.t(), :cancel | :reschedule) :: String.t() | nil
  def action_tooltip(meeting, action) do
    case action do
      :cancel ->
        case Policy.can_cancel_meeting?(meeting) do
          :ok -> nil
          {:error, reason} -> reason
        end

      :reschedule ->
        case Policy.can_reschedule_meeting?(meeting) do
          :ok -> nil
          {:error, reason} -> reason
        end
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

  @spec format_meeting_time(Ecto.Schema.t(), String.t()) :: String.t()
  def format_meeting_time(meeting, timezone) do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)
    local_start = DateTimeUtils.convert_to_timezone(meeting.start_time, timezone)
    local_end = DateTimeUtils.convert_to_timezone(meeting.end_time, timezone)

    start_time = LocaleFormat.format_time(local_start, locale)
    end_time = LocaleFormat.format_time(local_end, locale)
    "#{start_time} - #{end_time}"
  end
end
