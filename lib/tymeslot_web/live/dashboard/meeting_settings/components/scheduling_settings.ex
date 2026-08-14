defmodule TymeslotWeb.Dashboard.MeetingSettings.Components.SchedulingSettings do
  @moduledoc "Account-wide booking limit components for the meeting settings page."
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Component for configuring account-wide booking limits.

  Three optional caps on total bookings per day, week, and month across all
  meeting types; an empty field means no limit.
  """
  attr :profile, :map, required: true
  attr :myself, :any, required: true

  @spec booking_limits_setting(map()) :: Phoenix.LiveView.Rendered.t()
  def booking_limits_setting(assigns) do
    ~H"""
    <div>
      <label class="label">
        {dgettext("dashboard_meeting_types", "Booking Limits")}
      </label>

      <form
        id="booking-limits-form"
        phx-change="update_booking_limit"
        phx-debounce="500"
        phx-target={@myself}
        class="grid grid-cols-1 sm:grid-cols-3 gap-4"
      >
        <label class="space-y-1">
          <span class="text-token-sm font-medium text-tymeslot-700">
            {dgettext("dashboard_meeting_types", "Per day")}
          </span>
          <input
            type="number"
            min="1"
            max="500"
            step="1"
            name="max_bookings_per_day"
            value={@profile && @profile.max_bookings_per_day}
            placeholder={dgettext("dashboard_meeting_types", "No limit")}
            class="input"
          />
        </label>

        <label class="space-y-1">
          <span class="text-token-sm font-medium text-tymeslot-700">
            {dgettext("dashboard_meeting_types", "Per week")}
          </span>
          <input
            type="number"
            min="1"
            max="500"
            step="1"
            name="max_bookings_per_week"
            value={@profile && @profile.max_bookings_per_week}
            placeholder={dgettext("dashboard_meeting_types", "No limit")}
            class="input"
          />
        </label>

        <label class="space-y-1">
          <span class="text-token-sm font-medium text-tymeslot-700">
            {dgettext("dashboard_meeting_types", "Per month")}
          </span>
          <input
            type="number"
            min="1"
            max="500"
            step="1"
            name="max_bookings_per_month"
            value={@profile && @profile.max_bookings_per_month}
            placeholder={dgettext("dashboard_meeting_types", "No limit")}
            class="input"
          />
        </label>
      </form>

      <p class="mt-4 text-token-sm text-tymeslot-500 font-bold">
        {dgettext(
          "dashboard_meeting_types",
          "Maximum number of bookings you accept across all meeting types. Days at their cap disappear from your booking page. Leave a field empty for no limit."
        )}
      </p>
    </div>
    """
  end
end
