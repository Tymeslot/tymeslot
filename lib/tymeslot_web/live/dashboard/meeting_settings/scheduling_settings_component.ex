defmodule TymeslotWeb.Dashboard.MeetingSettings.SchedulingSettingsComponent do
  @moduledoc """
  LiveComponent encapsulating the account-wide booking limits.

  The buffers before and after meetings, the advance booking window and
  minimum notice belong to a named availability schedule and are edited on
  the availability page; what remains here are the caps that apply across
  every meeting type.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Profiles
  alias TymeslotWeb.Dashboard.MeetingSettings.Components.BookingLimitFields

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div>
      <%!-- The heading names the inputs, so it is not repeated as a label
           above them. --%>
      <.card
        title_id="booking-limits-heading"
        icon="hero-clock"
        title={dgettext("dashboard_meeting_types", "Booking Limits")}
        description={
          dgettext(
            "dashboard_meeting_types",
            "Maximum number of bookings you accept across all meeting types. Days at their cap disappear from your booking page. Leave a field empty for no limit."
          )
        }
      >
        <form id="booking-limits-form" phx-change="update_booking_limit" phx-target={@myself}>
          <BookingLimitFields.booking_limit_fields
            id="booking-limits"
            labelledby="booking-limits-heading"
            day={@profile && @profile.max_bookings_per_day}
            week={@profile && @profile.max_bookings_per_week}
            month={@profile && @profile.max_bookings_per_month}
            phx-debounce="500"
          />
        </form>
      </.card>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("update_booking_limit", %{"_target" => [field]} = params, socket)
      when field in ~w(max_bookings_per_day max_bookings_per_week max_bookings_per_month) do
    case Profiles.update_booking_limit(
           socket.assigns.profile,
           String.to_existing_atom(field),
           params[field]
         ) do
      {:ok, updated_profile} ->
        Flash.info(
          booking_limit_flash(Map.fetch!(updated_profile, String.to_existing_atom(field)))
        )

        send(self(), {:profile_updated, updated_profile})
        {:noreply, assign(socket, :profile, updated_profile)}

      {:error, _reason} ->
        Flash.error(
          dgettext("dashboard_meeting_types", "Booking limit must be between 1 and 500")
        )

        {:noreply, socket}
    end
  end

  def handle_event("update_booking_limit", _params, socket), do: {:noreply, socket}

  defp booking_limit_flash(nil), do: dgettext("dashboard_meeting_types", "Booking limit removed")

  defp booking_limit_flash(limit),
    do:
      dgettext("dashboard_meeting_types", "Booking limit updated to %{limit} bookings",
        limit: limit
      )
end
