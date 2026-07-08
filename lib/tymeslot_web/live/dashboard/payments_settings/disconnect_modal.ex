defmodule TymeslotWeb.Dashboard.PaymentsSettings.DisconnectModal do
  @moduledoc """
  Confirmation modal for disconnecting the host's Stripe account.

  Stateless function component rendered by `PaymentsSettingsComponent`. The
  Cancel/Disconnect actions dispatch `close_disconnect_modal` and `disconnect`
  events back to the parent component (`@myself`), which owns the modal's
  open/closed state and performs the disconnect.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :open, :boolean, required: true
  attr :pending_count, :integer, required: true
  attr :myself, :any, required: true

  @spec disconnect_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def disconnect_modal(assigns) do
    ~H"""
    <.modal
      :if={@open}
      id="disconnect-modal"
      show={true}
      on_cancel={JS.push("close_disconnect_modal", target: @myself)}
      size={:medium}
    >
      <:header>
        <span class="text-token-xl font-black tracking-tight">
          {dgettext("dashboard_payments", "Disconnect Stripe")}
        </span>
      </:header>

      <div class="space-y-4">
        <p class="text-tymeslot-700">
          {dgettext(
            "dashboard_payments",
            "Disconnect your Stripe account from Tymeslot? Existing payments remain visible, but new paid bookings will fail until you reconnect."
          )}
        </p>

        <.info_box :if={@pending_count > 0} variant={:warning}>
          {dngettext(
            "dashboard_payments",
            "You have %{count} pending booking awaiting payment. Disconnecting will cancel it.",
            "You have %{count} pending bookings awaiting payment. Disconnecting will cancel them.",
            @pending_count
          )}
        </.info_box>
      </div>

      <:footer>
        <div class="flex justify-end gap-3">
          <.action_button
            variant={:secondary}
            phx-click="close_disconnect_modal"
            phx-target={@myself}
          >
            {dgettext("dashboard_payments", "Cancel")}
          </.action_button>
          <.action_button variant={:danger} phx-click="disconnect" phx-target={@myself}>
            {dgettext("dashboard_payments", "Disconnect Stripe")}
          </.action_button>
        </div>
      </:footer>
    </.modal>
    """
  end
end
