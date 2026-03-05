defmodule TymeslotWeb.Dashboard.Automation.TelegramEmptyState do
  @moduledoc false
  use TymeslotWeb, :html

  attr :on_create, :any, required: true

  @spec telegram_empty_state(map()) :: Phoenix.LiveView.Rendered.t()
  def telegram_empty_state(assigns) do
    ~H"""
    <div class="card-glass text-center py-16">
      <div class="w-20 h-20 bg-turquoise-50 rounded-token-3xl mx-auto mb-6 flex items-center justify-center border-2 border-turquoise-100">
        <svg class="w-10 h-10 text-turquoise-600" viewBox="0 0 24 24" fill="currentColor">
          <path d="M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z" />
        </svg>
      </div>

      <h3 class="text-token-2xl font-black text-tymeslot-900 mb-3">No Telegram Integrations</h3>
      <p class="text-tymeslot-600 font-medium mb-8 max-w-md mx-auto">
        Connect Telegram to receive instant notifications when meetings are booked, cancelled, or rescheduled.
      </p>

      <button phx-click={@on_create} class="btn-primary">
        Add Telegram Account
      </button>
    </div>
    """
  end
end
