defmodule TymeslotWeb.OnboardingLive.OnboardingLayout do
  @moduledoc """
  Split-screen layout component for the onboarding flow.

  Renders a left content panel (progress dots, step content, navigation)
  and a right illustration panel (hidden on mobile).
  """

  use Phoenix.Component
  use TymeslotWeb, :verified_routes

  import TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  alias TymeslotWeb.OnboardingLive.StepConfig

  @doc """
  Renders the split-screen onboarding layout.

  ## Attributes

  * `current_step` - The current step atom
  * `steps` - Ordered list of step atoms
  * `show_skip_modal` - Whether the skip modal is visible

  ## Slots

  * `inner_block` - The step-specific content
  """
  attr :current_step, :atom, required: true
  attr :steps, :list, required: true
  attr :show_skip_modal, :boolean, default: false

  slot :inner_block, required: true

  @spec onboarding_layout(map()) :: Phoenix.LiveView.Rendered.t()
  def onboarding_layout(assigns) do
    ~H"""
    <div class="onboarding-container">
      <div class="onboarding-content-panel">
        <div class="onboarding-content-area">
          <%!-- Progress indicator --%>
          <div class="onboarding-progress">
            <div class="onboarding-progress-dots">
              <%= for step <- @steps do %>
                <div class={progress_dot_class(step, @current_step)} />
              <% end %>
            </div>
            <span class="onboarding-progress-label">
              Step {StepConfig.step_number(@current_step)} of {StepConfig.step_count()}
            </span>
          </div>

          <%!-- Step header --%>
          <div class="onboarding-step-header">
            <h1 class="onboarding-step-title">{StepConfig.step_title(@current_step)}</h1>
            <p class="onboarding-step-description">{StepConfig.step_description(@current_step)}</p>
          </div>

          <%!-- Step content --%>
          <div class="onboarding-slide-in-left">
            {render_slot(@inner_block)}
          </div>

          <%!-- Navigation --%>
          <div class="onboarding-nav">
            <%= if StepConfig.show_back_button?(@current_step) do %>
              <button type="button" phx-click="previous_step" class="btn-secondary inline-flex items-center px-5 py-2.5">
                <.icon name="hero-arrow-left-mini" class="w-4 h-4 mr-1" />
                Back
              </button>
            <% end %>

            <div class="onboarding-nav-spacer" />

            <button type="button" phx-click="next_step" class="btn-primary inline-flex items-center px-6 py-2.5">
              {StepConfig.next_button_text(@current_step)}
              <.icon name="hero-arrow-right-mini" class="w-4 h-4 ml-1" />
            </button>
          </div>

          <%= if StepConfig.show_skip_link?(@current_step) do %>
            <button type="button" phx-click="skip_step" class="onboarding-skip-link">
              {StepConfig.skip_link_text(@current_step)}
            </button>
          <% end %>
        </div>
      </div>

      <%!-- Illustration panel (hidden on mobile) --%>
      <div class="onboarding-illustration-panel">
        <img
          src={~p"/images/onboarding/#{StepConfig.illustration_file(@current_step)}"}
          alt={"Illustration for #{StepConfig.step_title(@current_step)}"}
        />
      </div>
    </div>
    """
  end

  defp progress_dot_class(step, current_step) do
    cond do
      StepConfig.step_completed?(step, current_step) ->
        "onboarding-progress-dot onboarding-progress-dot--completed"

      step == current_step ->
        "onboarding-progress-dot onboarding-progress-dot--current"

      true ->
        "onboarding-progress-dot onboarding-progress-dot--upcoming"
    end
  end
end
