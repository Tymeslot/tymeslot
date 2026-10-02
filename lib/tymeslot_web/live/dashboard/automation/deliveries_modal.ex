defmodule TymeslotWeb.Dashboard.Automation.DeliveriesModal do
  @moduledoc """
  Delivery history of one webhook: its recent stats and deliveries.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Dashboard.Automation.DeliveryComponents

  attr :show, :boolean, default: false
  attr :webhook, :map, required: true
  attr :deliveries, :list, required: true
  attr :stats, :map, required: true
  attr :time_format, :string, required: true
  attr :on_close, :any, required: true

  @spec deliveries_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def deliveries_modal(assigns) do
    ~H"""
    <CoreComponents.modal
      id="deliveries-modal"
      show={@show}
      on_cancel={@on_close}
      size={:large}
    >
      <:header>
        <div class="flex flex-col">
          <span>{@webhook.name}</span>
          <span class="text-tymeslot-500 font-medium font-mono text-token-xs mt-1">{@webhook.url}</span>
        </div>
      </:header>

      <div class="space-y-8">
        <DeliveryComponents.delivery_stats_grid stats={@stats} />

        <div>
          <div class="flex items-center justify-between mb-4">
            <h3 class="text-lg font-black text-tymeslot-900 flex items-center gap-2">
              <CoreComponents.icon name="hero-list-bullet" class="w-5 h-5" />
              {dgettext("dashboard_automation", "Recent Deliveries")}
            </h3>
            <div class="flex items-center gap-1.5 text-token-xs text-tymeslot-500 font-medium bg-tymeslot-50 px-2 py-1 rounded-token-lg border border-tymeslot-100">
              <CoreComponents.icon name="hero-information-circle" class="w-3.5 h-3.5" />
              {dgettext("dashboard_automation", "Test calls are not logged")}
            </div>
          </div>
          <DeliveryComponents.delivery_list deliveries={@deliveries} time_format={@time_format} />
        </div>
      </div>

      <:footer>
        <div class="flex justify-end">
          <.action_button variant={:primary} phx-click={@on_close}>
            {dgettext("dashboard_automation", "Close")}
          </.action_button>
        </div>
      </:footer>
    </CoreComponents.modal>
    """
  end
end
