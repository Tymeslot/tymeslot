defmodule TymeslotWeb.Dashboard.ThemeCustomization.ThemePreviewInline do
  @moduledoc """
  Renders an inline preview of the full theme (colors + background) based on the
  current customization. CSS variables are scoped to this component only.
  """
  use Phoenix.Component

  alias Tymeslot.ThemeCustomizations

  attr :theme_id, :string, required: true
  attr :customization, :map, required: true
  attr :class, :string, default: ""

  @spec preview(map()) :: Phoenix.LiveView.Rendered.t()
  def preview(assigns) do
    css_vars = ThemeCustomizations.generate_theme_css(assigns.theme_id, assigns.customization)

    assigns = assign(assigns, :css_vars, css_vars)

    ~H"""
    <div class={"rounded-lg overflow-hidden border border-gray-200 #{ @class }"}>
      <!-- Scope CSS variables to this wrapper via inline style -->
      <div class="relative" style={"#{@css_vars}"}>
        <!-- Background layer using the scoped CSS variables -->
        <div
          class="h-40 w-full"
          style="
            background: var(--theme-background, #f8fafc);
            background-image: var(--theme-background-image, none);
            background-size: cover;
            background-position: center;
            background-repeat: no-repeat;
          "
        >
        </div>
        
    <!-- Foreground demo card to showcase primary colors and surfaces -->
        <div class="absolute inset-0 flex items-center justify-center p-4">
          <div
            class="rounded-xl shadow-lg max-w-sm w-full"
            style="
              background: rgba(255,255,255,0.8);
              backdrop-filter: blur(6px);
              border: 1px solid rgba(255,255,255,0.3);
            "
          >
            <div class="p-4">
              <div class="flex items-center justify-between mb-3">
                <h4 class="font-semibold" style="color: var(--theme-text, #0f172a);">
                  Theme Preview
                </h4>
                <span
                  class="px-2 py-1 rounded text-xs"
                  style="background: var(--theme-primary, #06b6d4); color: white;"
                >
                  Primary
                </span>
              </div>
              <p class="text-sm mb-4" style="color: var(--theme-text-secondary, #475569);">
                This preview reflects your current color scheme and background.
              </p>
              <div class="flex gap-2">
                <button
                  type="button"
                  class="px-3 py-1.5 rounded text-sm"
                  style="
                    background: var(--theme-primary, #06b6d4);
                    color: white;
                    box-shadow: 0 2px 6px rgba(0,0,0,0.15);
                  "
                >
                  Confirm
                </button>
                <button
                  type="button"
                  class="px-3 py-1.5 rounded text-sm border"
                  style="
                    background: rgba(255,255,255,0.6);
                    color: var(--theme-text, #0f172a);
                    border-color: rgba(0,0,0,0.08);
                  "
                >
                  Secondary
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
