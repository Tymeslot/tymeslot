defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.LimitsSection do
  @moduledoc """
  Stateless function component for the meeting-type form's booking limits
  section.

  Three optional caps on how many bookings of this type the host accepts
  per day, week, and month; an empty field means no limit. The inputs are
  part of the surrounding meeting-type form (no nested form element); each
  change dispatches `update_booking_limits` back to the parent
  `MeetingTypeForm` (`@myself`), which owns the socket state and auto-save.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Dashboard.MeetingSettings.Components.BookingLimitFields

  attr :booking_limits, :map, required: true
  attr :myself, :any, required: true

  @spec limits_section(map()) :: Phoenix.LiveView.Rendered.t()
  def limits_section(assigns) do
    ~H"""
    <section class="space-y-4">
      <.subsection_header
        id="meeting-type-booking-limits-heading"
        icon="hero-adjustments-horizontal"
        title={dgettext("dashboard_meeting_form", "Booking limits")}
        description={
          dgettext(
            "dashboard_meeting_form",
            "Cap how many bookings of this type you accept. Leave a field empty for no limit."
          )
        }
      />

      <.card variant={:flat} padding={:sm}>
        <BookingLimitFields.booking_limit_fields
          id="meeting-type-booking-limits"
          labelledby="meeting-type-booking-limits-heading"
          as="meeting_type"
          day={@booking_limits["max_bookings_per_day"]}
          week={@booking_limits["max_bookings_per_week"]}
          month={@booking_limits["max_bookings_per_month"]}
          phx-change="update_booking_limits"
          phx-debounce="500"
          phx-target={@myself}
        />
      </.card>
    </section>
    """
  end
end
