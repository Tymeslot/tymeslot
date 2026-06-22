defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.GuestsSection do
  @moduledoc """
  Stateless function component for the meeting-type form's Guests section.

  Renders the "allow guests" toggle. When enabled, invitees can add extra
  guest email addresses on the public booking form; each guest receives a
  confirmation email with an RSVP link. The toggle dispatches
  `toggle_allow_guests` back to the parent `MeetingTypeForm` (`@myself`),
  which owns the socket state and auto-save.
  """

  use TymeslotWeb, :html

  attr :allow_guests, :boolean, required: true
  attr :max_guests, :integer, required: true
  attr :myself, :any, required: true

  @spec guests_section(map()) :: Phoenix.LiveView.Rendered.t()
  def guests_section(assigns) do
    ~H"""
    <section class="space-y-4">
      <div class="flex items-center gap-2">
        <.icon name="hero-user-group" class="w-5 h-5 text-turquoise-500" />
        <h3 class="text-token-base font-semibold text-tymeslot-800">Guests</h3>
      </div>

      <label class="card-glass flex items-start gap-3 p-4 cursor-pointer">
        <input
          type="checkbox"
          class="checkbox mt-0.5"
          checked={@allow_guests}
          phx-click="toggle_allow_guests"
          phx-target={@myself}
        />
        <div class="space-y-1">
          <p class="text-token-sm font-medium text-tymeslot-700">
            Let invitees add up to {@max_guests} guests to this meeting
          </p>
          <p class="text-token-sm text-tymeslot-500">
            Each guest is emailed a confirmation with their own link to accept or decline.
            You'll see every guest's response on your dashboard.
          </p>
        </div>
      </label>
    </section>
    """
  end
end
