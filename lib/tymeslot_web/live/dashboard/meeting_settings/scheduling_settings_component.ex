defmodule TymeslotWeb.Dashboard.MeetingSettings.SchedulingSettingsComponent do
  @moduledoc """
  LiveComponent encapsulating the account-wide booking limits.

  Buffer, advance booking window and minimum notice belong to a named
  availability schedule and are edited on the availability page; what remains
  here are the caps that apply across every meeting type.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Profiles
  alias TymeslotWeb.Dashboard.MeetingSettings.Components.SchedulingSettings

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="card-glass shadow-2xl shadow-tymeslot-200/50">
      <.section_header
        level={3}
        icon="hero-clock"
        title={dgettext("dashboard_meeting_types", "Booking Limits")}
        class="mb-10"
      />

      <div class="space-y-8">
        <SchedulingSettings.booking_limits_setting profile={@profile} myself={@myself} />
      </div>
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
