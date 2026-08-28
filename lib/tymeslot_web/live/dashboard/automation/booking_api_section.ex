defmodule TymeslotWeb.Dashboard.Automation.BookingApiSection do
  @moduledoc """
  Markup for the booking API section of the webhooks tab.

  Webhooks tell an external system what happened in Tymeslot; this token lets
  the same system book on the organiser's behalf. They are the two halves of
  one integration, so they share a tab.

  The token is shown in full whenever the endpoint is open, rather than only
  once at creation: it is the organiser's own secret, on the same footing as
  the free/busy feed link, and an integrator reconfiguring a CRM months later
  should not have to invalidate a working token to read it back.

  Rendering only: every interaction is pushed back to the owning LiveComponent
  through the `:myself` target passed in by the caller.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :token, :string, default: nil
  attr :endpoint_url, :string, required: true
  attr :myself, :any, required: true

  @spec booking_api_section(map()) :: Phoenix.LiveView.Rendered.t()
  def booking_api_section(assigns) do
    ~H"""
    <section class="space-y-4">
      <div class="flex items-center gap-2">
        <.icon name="hero-key" class="w-5 h-5 text-turquoise-500" />
        <h3 class="text-token-base font-semibold text-tymeslot-800">
          {dgettext("dashboard_automation", "Booking API")}
        </h3>
      </div>

      <div class="card-glass p-4 space-y-3">
        <p class="text-token-sm text-tymeslot-500">
          {dgettext(
            "dashboard_automation",
            "Let another system create bookings for you — a CRM booking a slot you agreed on a call, for instance. Your attendee is invited as usual, with their own cancel and reschedule links."
          )}
        </p>

        <code class="block w-full overflow-x-auto rounded-token-md bg-tymeslot-50 px-3 py-2 text-token-sm text-tymeslot-700 select-all">
          POST {@endpoint_url}
        </code>

        <%= if @token do %>
          <p class="text-token-sm text-tymeslot-500">
            {dgettext(
              "dashboard_automation",
              "Send this token as an Authorization: Bearer header. Treat it like a password — anyone holding it can put meetings in your diary."
            )}
          </p>

          <code class="block w-full overflow-x-auto rounded-token-md bg-tymeslot-50 px-3 py-2 text-token-sm text-tymeslot-700 select-all">
            {@token}
          </code>

          <div class="flex flex-wrap gap-2">
            <button
              type="button"
              class="btn btn-secondary"
              phx-click="regenerate_booking_api_token"
              phx-target={@myself}
            >
              {dgettext("dashboard_automation", "Regenerate token")}
            </button>
            <button
              type="button"
              class="btn btn-ghost"
              phx-click="disable_booking_api"
              phx-target={@myself}
            >
              {dgettext("dashboard_automation", "Disable booking API")}
            </button>
          </div>
        <% else %>
          <button
            type="button"
            class="btn btn-primary"
            phx-click="enable_booking_api"
            phx-target={@myself}
          >
            {dgettext("dashboard_automation", "Enable booking API")}
          </button>
        <% end %>
      </div>
    </section>
    """
  end
end
