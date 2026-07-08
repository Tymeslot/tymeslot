defmodule TymeslotWeb.Dashboard.Automation.WebhookEmptyState do
  @moduledoc """
  UI component for the webhook empty state.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Icons.IconComponents

  attr :on_create, :any, required: true

  @spec webhook_empty_state(map()) :: Phoenix.LiveView.Rendered.t()
  def webhook_empty_state(assigns) do
    ~H"""
    <div class="card-glass text-center py-16">
      <div class="w-20 h-20 bg-turquoise-50 rounded-token-3xl mx-auto mb-6 flex items-center justify-center border-2 border-turquoise-100">
        <IconComponents.icon name={:webhook} class="w-10 h-10 text-turquoise-600" />
      </div>

      <h3 class="text-token-2xl font-black text-tymeslot-900 mb-3">
        {dgettext("dashboard_automation", "No Webhooks Yet")}
      </h3>
      <p class="text-tymeslot-600 font-medium mb-8 max-w-md mx-auto">
        {dgettext(
          "dashboard_automation",
          "Set up webhooks to automatically trigger actions in n8n, Zapier, or your custom tools when bookings are created, cancelled, or rescheduled."
        )}
      </p>

      <button phx-click={@on_create} class="btn-primary">
        {dgettext("dashboard_automation", "Create Your First Webhook")}
      </button>
    </div>
    """
  end
end
