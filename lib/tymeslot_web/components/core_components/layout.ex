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
  attr :slug, :string, default: nil

  attr :navigable_steps, :list,
    default: [],
    doc: "the step numbers the step indicator may offer as clickable"

  attr :username_context, :string,
    default: nil,
    doc: "optional username shown in the page header for profile context"

  @spec page_layout(map()) :: Phoenix.LiveView.Rendered.t()
  def page_layout(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col">
      <%= if @show_steps do %>
        <div class="step-navigation-wrapper flex justify-center py-2 md:py-4">
          <div class="glass-morphism-card booker-card step-navigation-card">
            <div class="px-3 py-2">
              <StepNavigation.step_indicator
                current_step={@current_step}
                slug={@slug}
                navigable_steps={@navigable_steps}
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
end
