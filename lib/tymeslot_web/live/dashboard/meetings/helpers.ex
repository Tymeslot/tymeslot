defmodule TymeslotWeb.Live.Dashboard.Meetings.Helpers do
  @moduledoc false

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Utils.DateTimeUtils

  # Status helpers
  @spec past_meeting?(Ecto.Schema.t()) :: boolean()
  def past_meeting?(meeting) do
    DateTime.compare(meeting.start_time, DateTime.utc_now()) == :lt
  end

  # Policy helpers (surface booleans and tooltips)
  @spec can_cancel?(Ecto.Schema.t()) :: boolean()
  def can_cancel?(meeting) do
    case Policy.can_cancel_meeting?(meeting) do
      :ok -> true
      {:error, _} -> false
    end
  end

  @spec can_reschedule?(Ecto.Schema.t()) :: boolean()
  def can_reschedule?(meeting) do
    case Policy.can_reschedule_meeting?(meeting) do
      :ok -> true
      {:error, _} -> false
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
    local_time = DateTimeUtils.convert_to_timezone(meeting.start_time, timezone)
    Calendar.strftime(local_time, "%B %d, %Y")
  end

  @spec format_meeting_time(Ecto.Schema.t(), String.t()) :: String.t()
  def format_meeting_time(meeting, timezone) do
    local_start = DateTimeUtils.convert_to_timezone(meeting.start_time, timezone)
    local_end = DateTimeUtils.convert_to_timezone(meeting.end_time, timezone)

    start_time = Calendar.strftime(local_start, "%-I:%M %p")
    end_time = Calendar.strftime(local_end, "%-I:%M %p")
    "#{start_time} - #{end_time}"
  end
end
