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
  use Gettext, backend: TymeslotWeb.Gettext

  attr :allow_guests, :boolean, required: true
  attr :max_guests, :integer, required: true
  attr :myself, :any, required: true

  @spec guests_section(map()) :: Phoenix.LiveView.Rendered.t()
  def guests_section(assigns) do
    ~H"""
    <section class="space-y-4">
      <.subsection_header
        icon="hero-user-group"
        title={dgettext("dashboard_meeting_form", "Guests")}
      />

      <.setting_row
        id="allow-guests-toggle"
        label={
          dgettext(
            "dashboard_meeting_form",
            "Let invitees add up to %{max_guests} guests to this meeting",
            max_guests: @max_guests
          )
        }
        description={
          dgettext(
            "dashboard_meeting_form",
            "Each guest is emailed a confirmation with their own link to accept or decline. You'll see every guest's response on your dashboard."
          )
        }
        checked={@allow_guests}
        on_change="toggle_allow_guests"
        target={@myself}
      />
    </section>
    """
  end
end
