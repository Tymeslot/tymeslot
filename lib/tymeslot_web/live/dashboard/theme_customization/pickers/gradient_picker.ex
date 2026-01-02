defmodule TymeslotWeb.Dashboard.ThemeCustomization.Pickers.GradientPicker do
  @moduledoc """
  Function component for selecting gradient backgrounds in theme customization.
  """
  use TymeslotWeb, :html

  @doc """
  Renders the gradient picker.
  Expects assigns: customization, presets, myself
  """
  @spec gradient_picker(map()) :: Phoenix.LiveView.Rendered.t()
  def gradient_picker(assigns) do
    ~H"""
    <div class="theme-selection-grid cols-4">
      <%= for {gradient_id, gradient} <- @presets.gradients do %>
        <button
          type="button"
          class={[
            "gradient-preview-card hover-lift relative rounded-lg overflow-hidden transition ring-1 ring-gray-300 hover:ring-turquoise-300",
            if(@customization.background_value == gradient_id,
              do: "turquoise-glow ring-2 ring-turquoise-500",
              else: ""
            )
          ]}
          style={"background: #{gradient.value}"}
          phx-click="theme:select_background"
          phx-value-type="gradient"
          phx-value-id={gradient_id}
          phx-target={@myself}
        >
          <div class={[
            "gradient-preview-overlay",
            if(@customization.background_value == gradient_id, do: "bg-turquoise-50/20", else: "")
          ]}>
            <p class="gradient-preview-name">{gradient.name}</p>
          </div>
          <%= if @customization.background_value == gradient_id do %>
            <div class="selection-indicator">
              <svg class="w-4 h-4 text-white drop-shadow" fill="currentColor" viewBox="0 0 20 20">
                <path
                  fill-rule="evenodd"
                  d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z"
                  clip-rule="evenodd"
                />
              </svg>
            </div>
          <% end %>
        </button>
      <% end %>
    </div>
    """
  end
end
