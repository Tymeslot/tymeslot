defmodule TymeslotWeb.Components.Dashboard.Meetings.ParticipantPaymentPill do
  @moduledoc """
  The pill beside a participant of a paid group session saying what their
  seat's payment stands at: what they paid (and for how many seats, when
  more than one), refunded in full or in part, or disputed.

  Renders nothing for a free seat, for a payment in any other state (a
  checkout never completed has no participant to show it on), or when the
  payment was not loaded.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Association.NotLoaded
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias TymeslotWeb.Components.CoreComponents.Feedback

  import TymeslotWeb.Components.PaymentHelpers, only: [format_amount: 2]

  attr :payment, :any,
    required: true,
    doc: "the participant's `booking_payment`: a payment, nil, or not loaded"

  @spec participant_payment_pill(map()) :: Phoenix.LiveView.Rendered.t()
  def participant_payment_pill(assigns) do
    assigns = assign(assigns, :presentation, presentation(assigns.payment))

    ~H"""
    <Feedback.pill
      :if={@presentation}
      tone={elem(@presentation, 0)}
      class="flex-none"
      data-testid="participant-payment"
    >
      {elem(@presentation, 1)}
    </Feedback.pill>
    """
  end

  defp presentation(%BookingPaymentSchema{status: :paid} = payment),
    do: {:success, paid_label(payment)}

  # The bare statuses read as the payments table words them, from its domain.
  defp presentation(%BookingPaymentSchema{status: :refunded}),
    do: {:neutral, dgettext("dashboard_payments", "Refunded")}

  # Some money is back with the participant and some still with the host, so
  # it reads apart from a seat refunded in full.
  defp presentation(%BookingPaymentSchema{status: :partially_refunded} = payment),
    do:
      {:warning,
       dgettext("dashboard_bookings", "%{amount} refunded",
         amount: format_amount(payment.refunded_amount_cents, payment.currency)
       )}

  defp presentation(%BookingPaymentSchema{status: :disputed}),
    do: {:danger, dgettext("dashboard_payments", "Disputed")}

  # The card query preloads every participant's payment; one that is not
  # loaded is a caller that skipped it, and a pill left out beats a crashed
  # meetings list.
  defp presentation(%NotLoaded{}), do: nil

  defp presentation(_free_or_unsettled), do: nil

  # One whole phrase per shape, so a translation never stitches a count onto
  # an amount.
  defp paid_label(%{seats: seats} = payment) when is_integer(seats) and seats > 1,
    do:
      dngettext(
        "dashboard_bookings",
        "%{amount} paid · %{count} seat",
        "%{amount} paid · %{count} seats",
        seats,
        amount: format_amount(payment.amount_cents, payment.currency)
      )

  defp paid_label(payment),
    do:
      dgettext("dashboard_bookings", "%{amount} paid",
        amount: format_amount(payment.amount_cents, payment.currency)
      )
end
