defmodule TymeslotWeb.Components.CoreComponents.Layout do
  @moduledoc "Layout-related components extracted from CoreComponents."
  use Phoenix.Component

  # Application modules
  alias TymeslotWeb.StepNavigation

  # ========== LAYOUT ==========

  @doc """
  Main page layout wrapper with consistent structure.
  """
  slot :inner_block, required: true
  attr :show_steps, :boolean, default: false
  attr :current_step, :integer, default: 1
  attr :duration, :string, default: nil
  attr :username_context, :string, default: nil
  attr :theme_customization, :any, default: nil
  attr :has_custom_theme, :boolean, default: false

  @spec page_layout(map()) :: Phoenix.LiveView.Rendered.t()
  def page_layout(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col">
      <%= if @show_steps do %>
        <div class="flex justify-center py-2 md:py-4">
          <div class="glass-morphism-card step-navigation-card">
            <div class="px-3 py-2">
              <StepNavigation.step_indicator
                current_step={@current_step}
                duration={@duration}
                username_context={@username_context}
              />
            </div>
          </div>
        </div>
      <% end %>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Global footer component.
  """
  @spec footer(map()) :: Phoenix.LiveView.Rendered.t()
  def footer(assigns) do
    ~H"""
    <footer class="footer-gradient text-center">
      <p style="color: rgba(255,255,255,0.8);">
        Made with <span style="color: #ef4444;">❤</span>
        by
        <a
          href="https://lukabreitig.com"
          target="_blank"
          rel="noopener noreferrer"
          class="underline hover:text-white transition-colors"
          style="color: rgba(255,255,255,0.9);"
        >
          Luka Breitig
        </a>
      </p>
    </footer>
    """
  end
end
