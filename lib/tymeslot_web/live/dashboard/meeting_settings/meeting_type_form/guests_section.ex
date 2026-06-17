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
  attr :myself, :any, required: true

  @spec guests_section(map()) :: Phoenix.LiveView.Rendered.t()
  def guests_section(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex items-center gap-2">
        <.icon name="hero-user-group" class="w-5 h-5 text-turquoise-500" />
        <h3 class="text-token-base font-semibold text-tymeslot-700">Guests</h3>
      </div>

      <label class="flex items-center gap-3">
        <input
          type="checkbox"
          class="checkbox"
          checked={@allow_guests}
          phx-click="toggle_allow_guests"
          phx-target={@myself}
        />
        <span class="text-token-sm text-tymeslot-700">
          Let invitees add guests to this meeting
        </span>
      </label>

      <p class="text-token-sm text-tymeslot-600">
        Guests are emailed a confirmation with their own link to accept or decline.
        You'll see each guest's response on your dashboard.
      </p>
    </div>
    """
  end
end
