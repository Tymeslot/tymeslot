defmodule Tymeslot.Emails.Templates.AppointmentCancellation.RefundNotice do
  @moduledoc """
  The host-facing "you still hold their money" block of the cancellation email.

  A cancellation does not settle a paid booking. The host may have cancelled
  and chosen not to refund, or the attendee may have cancelled, in which case
  no refund is even offered and the money stays put. Either way the host is the
  only party who can act, and nothing else tells them: the cancellation email
  is otherwise payment-blind, and the payments screen shows payment status
  without meeting status, so a settled booking and an unrefunded cancellation
  look identical there.

  Built from the `:booking_payment` snapshot `AppointmentBuilder.from_meeting/1`
  already attaches to `appointment_details`, so this needs no query of its own.
  Returns `nil` for a free booking, a fully refunded one, or a disputed one, so
  the template short-circuits on a single value.

  Attendee-facing copy is deliberately not built here. Telling a booker money
  is owed that the host may never send would be worse than saying nothing.

  Internal to `Tymeslot.Emails.Templates.AppointmentCancellation`; nothing else
  should call it.
  """

  alias Tymeslot.Emails.Shared.{Formatting, Sanitise, Stack, Styles, Text}
  alias Tymeslot.MeetingPayments

  use Gettext, backend: TymeslotWeb.Gettext

  @typedoc "Host-facing refund notice, or `nil` when nothing is outstanding."
  @type notice :: %{amount: String.t()} | nil

  @doc """
  Builds the notice from the `:booking_payment` snapshot in
  `appointment_details`, or returns `nil` when no money is outstanding.
  """
  @spec build(map()) :: notice()
  def build(appointment_details) do
    payment = Map.get(appointment_details, :booking_payment)

    if MeetingPayments.refund_outstanding?(payment) do
      outstanding = MeetingPayments.refundable_remaining_cents(payment)
      %{amount: Formatting.format_currency(outstanding, payment.currency)}
    end
  end

  @doc "Renders the notice as MJML, or an empty string when there is none."
  @spec html(notice()) :: String.t()
  def html(nil), do: ""

  def html(%{amount: amount}) do
    """
    #{Text.section_title(dgettext("emails", "Refund outstanding"))}
    #{Stack.spaced("""
      <mj-section
        background-color="#{Styles.canvas_soft()}"
        border-radius="#{Styles.card_radius()}"
        padding="20px 26px"
        css-class="mobile-card email-canvas-soft"
      >
        <mj-column>
          <mj-text
            font-size="15px"
            color="#{Styles.text_color(:primary)}"
            line-height="1.7"
            align="left"
          >
            #{dgettext("emails", "You still hold %{amount} for this booking.", amount: strong(amount))}
          </mj-text>
          <mj-text
            font-size="13px"
            color="#{Styles.text_color(:muted)}"
            line-height="1.55"
            align="left"
            padding-top="12px"
          >
            #{dgettext("emails", "Cancelling does not refund anything on its own. Issue or decline the refund under Payments in your dashboard.")}
          </mj-text>
        </mj-column>
      </mj-section>
    """)}
    """
  end

  @doc "Renders the notice as plain text, or an empty string when there is none."
  @spec text(notice()) :: String.t()
  def text(nil), do: ""

  def text(%{amount: amount}) do
    """

    #{dgettext("emails", "REFUND OUTSTANDING:")}
    #{dgettext("emails", "You still hold %{amount} for this booking.", amount: amount)}
    #{dgettext("emails", "Cancelling does not refund anything on its own. Issue or decline the refund under Payments in your dashboard.")}
    """
  end

  # The bold markup rides in on the placeholder rather than living inside the
  # msgid, so the HTML and plain-text lines share one translation.
  defp strong(amount), do: "<strong>#{Sanitise.sanitize_for_email(amount)}</strong>"
end
