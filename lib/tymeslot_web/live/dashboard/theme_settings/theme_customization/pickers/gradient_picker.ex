defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.GradientPicker do
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
    <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-4">
      <%= for {gradient_id, gradient} <- @presets.gradients do %>
        <button
          type="button"
          class={[
            "group/gradient relative h-32 rounded-token-2xl overflow-hidden border-4 transition-all duration-500",
            if(@customization.background_value == gradient_id,
              do: "border-turquoise-400 shadow-2xl shadow-turquoise-500/20 scale-[1.02]",
              else: "border-white hover:border-turquoise-200"
            )
          ]}
          style={"background: #{gradient.value}"}
          phx-click="theme:select_background"
          phx-value-type="gradient"
          phx-value-id={gradient_id}
          phx-target={@myself}
        >
          <div class="absolute inset-0 bg-black/0 group-hover/gradient:bg-black/10 transition-colors"></div>
          <div class="absolute bottom-3 left-3 right-3 bg-white/90 backdrop-blur-md px-3 py-1.5 rounded-token-xl border border-white shadow-lg">
            <p class="text-token-2xs font-black uppercase tracking-[0.1em] text-tymeslot-900 text-center truncate">{gradient.name}</p>
          </div>
          
          <%= if @customization.background_value == gradient_id do %>
            <div class="absolute top-3 right-3 w-6 h-6 bg-turquoise-500 text-white rounded-full flex items-center justify-center shadow-lg animate-in zoom-in">
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M5 13l4 4L19 7" />
              </svg>
            </div>
          <% end %>
        </button>
      <% end %>
    </div>
    """
  end
end
