defmodule TymeslotWeb.Dashboard.PaymentsSettings.RefundModal do
  @moduledoc """
  Refund modal for a single booking payment.

  Stateless function component rendered by `PaymentsSettingsComponent`. Renders
  nothing when `payment` is nil. The full/partial radios and amount input
  dispatch `submit_refund`/`close_refund_modal` back to the parent component
  (`@myself`), which owns the modal state and performs the refund.

  A refund still pending counts against what can be refunded, and is shown
  as being processed; while pending refunds hold all that remains, the
  submit is disabled. What a lost dispute took back is shown apart from
  the refunds, since the host made no refund of it.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.Money

  import TymeslotWeb.Components.PaymentHelpers, only: [format_amount: 2]

  attr :payment, :map, required: true
  attr :submitting, :boolean, required: true
  attr :error, :string, default: nil
  attr :form, :map, default: %{type: "full", amount: ""}, doc: "what the host last submitted"
  attr :myself, :any, required: true

  @spec refund_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def refund_modal(%{payment: nil} = assigns), do: ~H""

  def refund_modal(assigns) do
    assigns =
      assign(assigns,
        remaining: MeetingPayments.refundable_remaining_cents(assigns.payment),
        pending: MeetingPayments.pending_refund_cents(assigns.payment)
      )

    ~H"""
    <.modal
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

        <.refund_figures payment={@payment} remaining={@remaining} pending={@pending} />

        <p class="text-token-sm text-tymeslot-700">
          {dgettext(
            "dashboard_payments",
            "The attendee receives the full amount you refund. Tymeslot's platform fee is reversed proportionally; Stripe processing fees on the original charge stay with you."
          )}
        </p>

        <form
          id="refund-form"
          phx-submit="submit_refund"
          phx-target={@myself}
          class="space-y-4"
          novalidate
        >
          <input type="hidden" name="payment_id" value={@payment.id} />

          <fieldset class="space-y-2">
            <legend class="text-token-sm font-semibold text-tymeslot-700">
              {dgettext("dashboard_payments", "Refund type")}
            </legend>
            <label class="flex items-center gap-2 text-token-sm">
              <.input
                type="radio"
                name="refund_type"
                value="full"
                checked={@form.type == "full"}
                phx-click={JS.set_attribute({"data-refund-type", "full"}, to: "#refund-form")}
              /> {dgettext("dashboard_payments", "Full refund")} ({format_amount(
                @remaining,
                @payment.currency
              )})
            </label>
            <label class="flex items-center gap-2 text-token-sm">
              <.input
                type="radio"
                name="refund_type"
                value="partial"
                checked={@form.type == "partial"}
                phx-click={JS.set_attribute({"data-refund-type", "partial"}, to: "#refund-form")}
              /> {dgettext("dashboard_payments", "Partial refund")}
            </label>
          </fieldset>

          <.input
            type="number"
            name="amount"
            label={dgettext("dashboard_payments", "Partial amount")}
            min="0.01"
            max={Money.to_major_string(@remaining, @payment.currency)}
            step="0.01"
            placeholder="0.00"
            value={@form.amount}
            errors={List.wrap(@error)}
          >
            <%!-- The tag sits on the side the locale writes the symbol. --%>
            <:leading_icon :if={!Money.symbol_after?(Gettext.get_locale(TymeslotWeb.Gettext))}>
              <span class="text-tymeslot-400 font-bold text-token-sm tracking-tight whitespace-nowrap">
                {Money.symbol(@payment.currency)}
              </span>
            </:leading_icon>
            <:trailing_icon :if={Money.symbol_after?(Gettext.get_locale(TymeslotWeb.Gettext))}>
              <span class="text-tymeslot-400 font-bold text-token-sm tracking-tight whitespace-nowrap">
                {String.trim(Money.symbol(@payment.currency))}
              </span>
            </:trailing_icon>
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
            disabled={@remaining == 0 and @pending > 0}
            aria-describedby={if @pending > 0, do: "refund-pending"}
            loading_text={dgettext("dashboard_payments", "Refunding...")}
          >
            {dgettext("dashboard_payments", "Issue refund")}
          </.loading_button>
        </div>
      </:footer>
    </.modal>
    """
  end

  attr :payment, :map, required: true
  attr :remaining, :integer, required: true
  attr :pending, :integer, required: true

  # What the payment took and where it went; one figure per line.
  defp refund_figures(assigns) do
    ~H"""
    <div class="rounded-token-md border border-tymeslot-100 bg-tymeslot-50 p-4 text-token-sm space-y-1">
      <p>
        {dgettext("dashboard_payments", "Original charge:")}
        <strong>{format_amount(@payment.amount_cents, @payment.currency)}</strong>
      </p>
      <p>
        {dgettext("dashboard_payments", "Already refunded:")}
        <strong>{format_amount(MeetingPayments.stripe_refunded_cents(@payment), @payment.currency)}</strong>
      </p>
      <%!-- Money a lost dispute took back is not a refund, so it gets its own line. --%>
      <p :if={@payment.disputed_lost_cents > 0}>
        {dgettext("dashboard_payments", "Lost in a dispute:")}
        <strong>{format_amount(@payment.disputed_lost_cents, @payment.currency)}</strong>
      </p>
      <p :if={@pending > 0} id="refund-pending">
        {dgettext("dashboard_payments", "%{amount} being processed",
          amount: format_amount(@pending, @payment.currency)
        )}
      </p>
      <p>
        {dgettext("dashboard_payments", "Remaining refundable:")}
        <strong>{format_amount(@remaining, @payment.currency)}</strong>
      </p>
    </div>
    """
  end
end
