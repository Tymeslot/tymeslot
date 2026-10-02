defmodule TymeslotWeb.Dashboard.Automation.ChatDeliveriesModal do
  @moduledoc """
  Delivery history of one chat integration, Slack or Telegram.

  The two render identically; the caller passes the integration, the modal
  `id` and the `on_close` event that set them apart.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Dashboard.Automation.DeliveryComponents

  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :integration, :map, required: true
  attr :deliveries, :list, required: true
  attr :stats, :map, default: nil
  attr :time_format, :string, required: true
  attr :on_close, :any, required: true

  @spec chat_deliveries_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def chat_deliveries_modal(assigns) do
    ~H"""
    <CoreComponents.modal id={@id} show={@show} on_cancel={@on_close} size={:large}>
      <:header>
        {dgettext("dashboard_automation", "Delivery History - %{name}", name: @integration.name)}
      </:header>

      <div class="space-y-8">
        <DeliveryComponents.delivery_stats_grid stats={@stats} />
        <DeliveryComponents.delivery_list deliveries={@deliveries} time_format={@time_format} />
      </div>

      <:footer>
        <div class="flex justify-end">
          <CoreComponents.action_button variant={:primary} phx-click={@on_close}>
            {dgettext("dashboard_automation", "Close")}
          </CoreComponents.action_button>
        </div>
      </:footer>
    </CoreComponents.modal>
    """
  end
end
