defmodule TymeslotWeb.Dashboard.PaymentsSettings.DisconnectModal do
  @moduledoc """
  Confirmation modal for disconnecting the host's Stripe account.

  Stateless function component rendered by `PaymentsSettingsComponent`. The
  Cancel/Disconnect actions dispatch `close_disconnect_modal` and `disconnect`
  events back to the parent component (`@myself`), which owns the modal's
  open/closed state and performs the disconnect.

  Two consequences are named before the host confirms, because both are
  invisible afterwards. `@pending_count` is what the disconnect will cancel;
  `@outstanding_refunds` is what it will not touch and can no longer settle,
  money the host is already holding on the attendee's behalf and will have to
  refund from their Stripe dashboard instead.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  import TymeslotWeb.Components.PaymentHelpers, only: [format_amount: 2]

  attr :open, :boolean, required: true
  attr :pending_count, :integer, required: true
  attr :outstanding_refunds, :map, required: true
  attr :myself, :any, required: true

  @spec disconnect_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def disconnect_modal(assigns) do
    ~H"""
    <.confirm_modal
      :if={@open}
      id="disconnect-modal"
      show
      title={dgettext("dashboard_payments", "Disconnect Stripe")}
      confirm_label={dgettext("dashboard_payments", "Disconnect Stripe")}
      on_cancel={JS.push("close_disconnect_modal", target: @myself)}
      on_confirm={JS.push("disconnect", target: @myself)}
      data-testid="confirm-disconnect-stripe"
    >
      <p>
        {dgettext(
          "dashboard_payments",
          "Disconnect your Stripe account from Tymeslot? Existing payments remain visible, but new paid bookings will fail until you reconnect."
        )}
      </p>

      <:extra :if={@pending_count > 0 or @outstanding_refunds.count > 0}>
        <.info_box :if={@pending_count > 0} variant={:warning}>
          {dngettext(
            "dashboard_payments",
            "You have %{count} pending booking awaiting payment. Disconnecting will cancel it.",
            "You have %{count} pending bookings awaiting payment. Disconnecting will cancel them.",
            @pending_count
          )}
        </.info_box>

        <.info_box :if={@outstanding_refunds.count > 0} variant={:warning}>
          {dngettext(
            "dashboard_payments",
            "You still owe %{count} refund totalling %{total}. Disconnecting does not issue it, and afterwards you will have to refund it from your Stripe dashboard.",
            "You still owe %{count} refunds totalling %{total}. Disconnecting does not issue them, and afterwards you will have to refund them from your Stripe dashboard.",
            @outstanding_refunds.count,
            total: format_totals(@outstanding_refunds.totals)
          )}
        </.info_box>
      </:extra>
    </.confirm_modal>
    """
  end

  # A host who has changed their default currency can be holding money in more
  # than one, so the totals arrive already split per currency and are listed
  # rather than summed into a figure that would mean nothing.
  defp format_totals(totals),
    do: Enum.map_join(totals, ", ", &format_amount(&1.amount_cents, &1.currency))
end
