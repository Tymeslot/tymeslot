defmodule TymeslotWeb.Components.CoreComponents.Feedback do
  @moduledoc "Feedback/status components extracted from CoreComponents."
  use Phoenix.Component

  # ========== FEEDBACK ==========

  @doc """
  Renders a loading spinner.
  """
  @spec spinner(map()) :: Phoenix.LiveView.Rendered.t()
  def spinner(assigns) do
    ~H"""
    <svg class="spinner" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
      </circle>
      <path
        class="opacity-75"
        fill="currentColor"
        d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
      >
      </path>
    </svg>
    """
  end

  @doc """
  Renders an empty state display.
  """
  attr :message, :string, required: true
  attr :secondary_message, :string, default: nil
  slot :icon, required: true

  @spec empty_state(map()) :: Phoenix.LiveView.Rendered.t()
  def empty_state(assigns) do
    ~H"""
    <div class="h-full flex items-center justify-center">
      <div class="text-center p-4">
        <svg
          class="w-12 h-12 mx-auto mb-2 text-gray-400"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          {render_slot(@icon)}
        </svg>
        <p class="text-sm font-medium" style="color: rgba(255,255,255,0.8);">
          {@message}
        </p>
        <%= if @secondary_message do %>
          <p class="text-xs mt-1" style="color: rgba(255,255,255,0.6);">
            {@secondary_message}
          </p>
        <% end %>
      </div>
    </div>
    """
  end
end
