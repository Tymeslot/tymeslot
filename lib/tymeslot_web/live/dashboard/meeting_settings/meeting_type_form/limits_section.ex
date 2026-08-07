defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.LimitsSection do
  @moduledoc """
  Stateless function component for the meeting-type form's booking limits
  section.

  Three optional caps on how many bookings of this type the host accepts
  per day, week, and month; an empty field means no limit. The inputs are
  part of the surrounding meeting-type form (no nested form element), named
  so they serialise on the create submit; each change also dispatches
  `update_booking_limits` back to the parent `MeetingTypeForm` (`@myself`),
  which owns the socket state and auto-save.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :booking_limits, :map, required: true
  attr :myself, :any, required: true

  @spec limits_section(map()) :: Phoenix.LiveView.Rendered.t()
  def limits_section(assigns) do
    ~H"""
    <section class="space-y-4">
      <div class="flex items-center gap-2">
        <.icon name="hero-adjustments-horizontal" class="w-5 h-5 text-turquoise-500" />
        <h3 class="text-token-base font-semibold text-tymeslot-800">
          {dgettext("dashboard_meeting_form", "Booking limits")}
        </h3>
      </div>

      <div class="card-glass p-4 space-y-4">
        <p class="text-token-sm text-tymeslot-500">
          {dgettext(
            "dashboard_meeting_form",
            "Cap how many bookings of this type you accept. Leave a field empty for no limit."
          )}
        </p>

        <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
          <label class="space-y-1">
            <span class="text-token-sm font-medium text-tymeslot-700">
              {dgettext("dashboard_meeting_form", "Per day")}
            </span>
            <input
              type="number"
              min="1"
              max="500"
              step="1"
              name="meeting_type[max_bookings_per_day]"
              value={@booking_limits["max_bookings_per_day"]}
              placeholder={dgettext("dashboard_meeting_form", "No limit")}
              class="input"
              phx-change="update_booking_limits"
              phx-debounce="500"
              phx-target={@myself}
            />
          </label>

          <label class="space-y-1">
            <span class="text-token-sm font-medium text-tymeslot-700">
              {dgettext("dashboard_meeting_form", "Per week")}
            </span>
            <input
              type="number"
              min="1"
              max="500"
              step="1"
              name="meeting_type[max_bookings_per_week]"
              value={@booking_limits["max_bookings_per_week"]}
              placeholder={dgettext("dashboard_meeting_form", "No limit")}
              class="input"
              phx-change="update_booking_limits"
              phx-debounce="500"
              phx-target={@myself}
            />
          </label>

          <label class="space-y-1">
            <span class="text-token-sm font-medium text-tymeslot-700">
              {dgettext("dashboard_meeting_form", "Per month")}
            </span>
            <input
              type="number"
              min="1"
              max="500"
              step="1"
              name="meeting_type[max_bookings_per_month]"
              value={@booking_limits["max_bookings_per_month"]}
              placeholder={dgettext("dashboard_meeting_form", "No limit")}
              class="input"
              phx-change="update_booking_limits"
              phx-debounce="500"
              phx-target={@myself}
            />
          </label>
        </div>
      </div>
    </section>
    """
  end
end
