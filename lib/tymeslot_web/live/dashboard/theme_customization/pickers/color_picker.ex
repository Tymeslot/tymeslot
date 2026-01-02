defmodule TymeslotWeb.Dashboard.ThemeCustomization.Pickers.ColorPicker do
  @moduledoc """
  Function component for selecting solid color backgrounds in theme customization.
  """
  use TymeslotWeb, :html

  @doc """
  Renders the color picker.
  Expects assigns: customization, myself
  """
  @spec color_picker(map()) :: Phoenix.LiveView.Rendered.t()
  def color_picker(assigns) do
    ~H"""
    <div class="theme-section">
      <p class="text-sm text-gray-600 mb-4">Select a solid background color:</p>
      <div class="flex flex-wrap gap-3">
        <%= for color <- ["#0f172a", "#1e1b4b", "#431407", "#082f49", "#052e16", "#4c0519", "#111827", "#1a202c"] do %>
          <div class={[
            "rounded-lg p-1 transition",
            if(@customization.background_value == color,
              do: "bg-turquoise-50",
              else: "bg-transparent"
            )
          ]}>
            <button
              type="button"
              class={[
                "duration-card hover-lift",
                "w-12 h-12 rounded-md border ring-1 ring-gray-300 hover:ring-turquoise-300 hover:shadow",
                if(@customization.background_value == color,
                  do: "selected turquoise-glow ring-2 ring-turquoise-500 border-turquoise-500",
                  else: "border-gray-200"
                )
              ]}
              style={"background-color: #{color}"}
              phx-click="theme:select_background"
              phx-value-type="color"
              phx-value-id={color}
              phx-target={@myself}
            >
              <%= if @customization.background_value == color do %>
                <svg class="w-6 h-6 text-white mx-auto" fill="currentColor" viewBox="0 0 20 20">
                  <path
                    fill-rule="evenodd"
                    d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z"
                    clip-rule="evenodd"
                  />
                </svg>
              <% end %>
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
