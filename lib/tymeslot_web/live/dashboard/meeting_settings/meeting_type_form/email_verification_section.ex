defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.EmailVerificationSection do
  @moduledoc """
  Stateless function component for the meeting-type form's email verification
  toggle.

  While it is on, a booking counts only once the invitee clicks the link
  emailed to them; until then the slot is held and the host hears nothing.

  The setting excludes group bookings and payments: while either is on, the
  toggle renders disabled with the reason, the parent guards the event
  server-side and the changeset enforces the rule. Turning it off is never
  blocked, so a type that somehow carries both settings can always be fixed.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :requires_email_verification, :boolean, required: true
  attr :payment_required, :boolean, default: false
  attr :group_bookings_enabled, :boolean, default: false
  attr :errors, :list, default: []
  attr :myself, :any, required: true

  @spec email_verification_section(map()) :: Phoenix.LiveView.Rendered.t()
  def email_verification_section(assigns) do
    assigns =
      assign(
        assigns,
        :toggle_disabled,
        (assigns.group_bookings_enabled or assigns.payment_required) and
          not assigns.requires_email_verification
      )

    ~H"""
    <section class="space-y-4">
      <.subsection_header
        icon="hero-envelope"
        title={dgettext("dashboard_meeting_form", "Email confirmation")}
      />

      <.setting_row
        id="requires-email-verification-toggle"
        label={dgettext("dashboard_meeting_form", "Ask invitees to confirm their email")}
        description={
          dgettext(
            "dashboard_meeting_form",
            "Bookings count only once the invitee clicks the link we email them. Until then the time is held for up to 30 minutes, and you are not notified."
          )
        }
        checked={@requires_email_verification}
        disabled={@toggle_disabled}
        on_change="toggle_requires_email_verification"
        target={@myself}
        data-testid="requires-email-verification-toggle"
      >
        <:disabled_reason>
          <%= if @group_bookings_enabled do %>
            {dgettext(
              "dashboard_meeting_form",
              "Turn off group bookings to ask invitees to confirm their email."
            )}
          <% else %>
            {dgettext(
              "dashboard_meeting_form",
              "Turn off payments to ask invitees to confirm their email. Paying already confirms who they are."
            )}
          <% end %>
        </:disabled_reason>
      </.setting_row>

      <p :for={error <- @errors} class="text-token-sm text-red-600">{error}</p>
    </section>
    """
  end
end
