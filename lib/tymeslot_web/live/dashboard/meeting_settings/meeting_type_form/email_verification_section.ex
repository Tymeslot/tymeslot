defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.EmailVerificationSection do
  @moduledoc """
  Stateless function component for the meeting-type form's email verification
  toggle.

  While it is on, a booking counts only once the invitee clicks the link
  emailed to them; until then the slot is held and the host hears nothing.

  The setting excludes payments and series: while either is on, the toggle
  renders disabled with the reason, the parent guards the event server-side
  and the changeset enforces the rule. Turning it off is never
  blocked, so a type that somehow carries both settings can always be fixed.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.EmailVerification

  attr :requires_email_verification, :boolean, required: true
  attr :payment_required, :boolean, default: false
  attr :series_enabled, :boolean, default: false
  attr :errors, :list, default: []
  attr :myself, :any, required: true

  @spec email_verification_section(map()) :: Phoenix.LiveView.Rendered.t()
  def email_verification_section(assigns) do
    assigns =
      assign(
        assigns,
        :toggle_disabled,
        (assigns.payment_required or assigns.series_enabled) and
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
          dngettext(
            "dashboard_meeting_form",
            "Bookings count only once the invitee clicks the link we email them. Until then the time is held for up to %{count} minute, and you are not notified.",
            "Bookings count only once the invitee clicks the link we email them. Until then the time is held for up to %{count} minutes, and you are not notified.",
            EmailVerification.hold_minutes()
          )
        }
        checked={@requires_email_verification}
        disabled={@toggle_disabled}
        on_change="toggle_requires_email_verification"
        target={@myself}
        data-testid="requires-email-verification-toggle"
      >
        <:disabled_reason>
          <%= if @payment_required do %>
            {dgettext(
              "dashboard_meeting_form",
              "Turn off payments to ask invitees to confirm their email. Paying already confirms who they are."
            )}
          <% else %>
            {dgettext(
              "dashboard_meeting_form",
              "Turn off series booking to ask invitees to confirm their email. A series confirms all its sessions at once."
            )}
          <% end %>
        </:disabled_reason>
      </.setting_row>

      <p :for={error <- @errors} class="text-token-sm text-red-600">{error}</p>
    </section>
    """
  end
end
