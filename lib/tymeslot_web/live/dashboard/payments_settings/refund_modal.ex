defmodule TymeslotWeb.Dashboard.PaymentsSettings.RefundModal do
  @moduledoc """
  Refund modal for a single booking payment.

  Stateless function component rendered by `PaymentsSettingsComponent`. Renders
  nothing when `payment` is nil. The full/partial radios and amount input
  dispatch `submit_refund`/`close_refund_modal` back to the parent component
  (`@myself`), which owns the modal state and performs the refund.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.MeetingPayments

  import TymeslotWeb.Components.PaymentHelpers, only: [format_amount: 2, currency_symbol: 1]

  attr :payment, :map, required: true
  attr :submitting, :boolean, required: true
  attr :myself, :any, required: true

  @spec refund_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def refund_modal(assigns) do
    ~H"""
    <.modal
      :if={@payment}
      id="refund-modal"
      show={true}
      on_cancel={JS.push("close_refund_modal", target: @myself)}
      size={:medium}
    >
      <:header>
        <span class="text-xl font-black tracking-tight">
          {dgettext("dashboard_payments", "Refund payment")}
        </span>
      </:header>

      <div class="space-y-4">
        <p class="text-tymeslot-700">
          {dgettext("dashboard_payments", "Refund %{attendee} for %{meeting_type}.",
            attendee: @payment.attendee_name || @payment.attendee_email,
            meeting_type: @payment.meeting_type_name
          )}
        </p>

        <div class="rounded-token-md border border-tymeslot-100 bg-tymeslot-50 p-4 text-token-sm space-y-1">
          <p>
            {dgettext("dashboard_payments", "Original charge:")}
            <strong>{format_amount(@payment.amount_cents, @payment.currency)}</strong>
          </p>
          <p>
            {dgettext("dashboard_payments", "Already refunded:")}
            <strong>{format_amount(@payment.refunded_amount_cents, @payment.currency)}</strong>
          </p>
          <p>
            {dgettext("dashboard_payments", "Remaining refundable:")}
            <strong>{format_amount(
              MeetingPayments.refundable_remaining_cents(@payment),
              @payment.currency
            )}</strong>
          </p>
        </div>

        <p class="text-token-sm text-tymeslot-700">
          {dgettext(
            "dashboard_payments",
            "The attendee receives the full amount you refund. Tymeslot's platform fee is reversed proportionally; Stripe processing fees on the original charge stay with you."
          )}
        </p>

        <form id="refund-form" phx-submit="submit_refund" phx-target={@myself} class="space-y-4">
          <input type="hidden" name="payment_id" value={@payment.id} />

          <fieldset class="space-y-2">
            <legend class="text-token-sm font-semibold text-tymeslot-700">
              {dgettext("dashboard_payments", "Refund type")}
            </legend>
            <label class="flex items-center gap-2 text-token-sm">
              <input
                type="radio"
                name="refund_type"
                value="full"
                checked
                phx-click={JS.set_attribute({"data-refund-type", "full"}, to: "#refund-form")}
              /> {dgettext("dashboard_payments", "Full refund")} ({format_amount(
                MeetingPayments.refundable_remaining_cents(@payment),
                @payment.currency
              )})
            </label>
            <label class="flex items-center gap-2 text-token-sm">
              <input
                type="radio"
                name="refund_type"
                value="partial"
                phx-click={JS.set_attribute({"data-refund-type", "partial"}, to: "#refund-form")}
              /> {dgettext("dashboard_payments", "Partial refund")}
            </label>
          </fieldset>

          <.input
            type="number"
            name="amount"
            label={dgettext("dashboard_payments", "Partial amount")}
            min="0.01"
            max={MeetingPayments.refundable_remaining_cents(@payment) / 100}
            step="0.01"
            placeholder="0.00"
          >
            <:leading_icon>
              <span class="text-tymeslot-400 font-bold text-token-sm tracking-tight whitespace-nowrap">
                {currency_symbol(@payment.currency)}
              </span>
            </:leading_icon>
          </.input>
        </form>
      </div>

      <:footer>
        <div class="flex justify-end gap-3">
          <.action_button variant={:secondary} phx-click="close_refund_modal" phx-target={@myself}>
            {dgettext("dashboard_payments", "Cancel")}
          </.action_button>
          <.loading_button
            type="submit"
            form="refund-form"
            variant={:danger}
            loading={@submitting}
            loading_text={dgettext("dashboard_payments", "Refunding...")}
          >
            {dgettext("dashboard_payments", "Issue refund")}
          </.loading_button>
        </div>
      </:footer>
    </.modal>
    """
  end
end
