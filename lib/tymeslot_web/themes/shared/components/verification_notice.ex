defmodule TymeslotWeb.Themes.Shared.Components.VerificationNotice do
  @moduledoc """
  What a booking visitor is told about confirming their email address, on a
  meeting type that requires it (`Tymeslot.Meetings.EmailVerification`).

    * `line/1`: one muted line on the booking form, beside the approval
      notice, saying a link will follow by email. Rendered in owner preview
      too: it describes what guests see, though a simulated booking skips
      verification.
    * `resend/1`: on the confirmation step while the booking waits for that
      link, the "Resend email" button and the outcome of the last press. The
      press is the LiveView's `resend_verification_email` event, handled once
      for every theme by `TymeslotWeb.Themes.Shared.VerificationResend`, which
      sets the `state` this renders.

  Neutral class names here; the styling is shared by every theme, in
  `assets/css/scheduling/shared/components/verification-notice.css`, through
  the tokens the approval notice already reads.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  alias Tymeslot.Meetings.EmailVerification

  # The states after which there is nothing left to resend.
  @final_states [:limit_reached, :expired, :used]

  attr :meeting_type, :any, required: true
  attr :class, :string, default: nil

  @doc "The booking form's line, rendered only for a type that requires verification."
  @spec line(map()) :: Phoenix.LiveView.Rendered.t()
  def line(assigns) do
    ~H"""
    <p
      :if={EmailVerification.required?(@meeting_type)}
      class={["verification-notice", @class]}
      data-testid="verification-notice"
    >
      <.icon name="hero-envelope-micro" class="verification-notice-icon" />
      <span>{dgettext("booking", "We'll email you a link to confirm this booking.")}</span>
    </p>
    """
  end

  attr :state, :atom,
    default: nil,
    values: [nil, :sent, :retry, :rate_limited | @final_states],
    doc: "the outcome of the last press, nil before any"

  attr :class, :string, default: nil

  @doc """
  The "Resend email" button and what the last press did. The button is
  disabled while a resend has just gone out, and gone once nothing more can
  be sent.
  """
  @spec resend(map()) :: Phoenix.LiveView.Rendered.t()
  def resend(assigns) do
    assigns = assign(assigns, :final, assigns.state in @final_states)

    ~H"""
    <div class={["verification-resend", @class]} data-testid="verification-resend">
      <button
        :if={!@final}
        type="button"
        class="verification-resend-button"
        phx-click="resend_verification_email"
        phx-disable-with={dgettext("booking_confirmation", "Sending…")}
        disabled={@state == :sent}
        data-testid="resend-verification"
      >
        {button_label(@state)}
      </button>
      <p
        :if={@state}
        class="verification-resend-status"
        role="status"
        data-testid="resend-verification-status"
      >
        {status_text(@state)}
      </p>
    </div>
    """
  end

  defp button_label(:sent), do: dgettext("booking_confirmation", "Sent")
  defp button_label(_state), do: dgettext("booking_confirmation", "Resend email")

  defp status_text(:sent),
    do: dgettext("booking_confirmation", "Sent again. It can take a minute to arrive.")

  defp status_text(:retry),
    do: dgettext("booking_confirmation", "The email could not be sent. Please try again.")

  defp status_text(:rate_limited),
    do: dgettext("booking_confirmation", "Too many attempts. Try again in a moment.")

  defp status_text(:limit_reached),
    do:
      dgettext(
        "booking_confirmation",
        "We cannot send the email again. If it has not arrived, check your spam folder."
      )

  defp status_text(:expired),
    do:
      dgettext(
        "booking_confirmation",
        "The time was released because the booking was not confirmed in time. Please book again."
      )

  defp status_text(:used),
    do:
      dgettext(
        "booking_confirmation",
        "This booking is no longer waiting for your confirmation, so there is nothing to resend."
      )
end
