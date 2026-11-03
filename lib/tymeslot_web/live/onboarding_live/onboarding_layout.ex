defmodule TymeslotWeb.OnboardingLive.OnboardingLayout do
  @moduledoc """
  The layout every onboarding step sits in: a question column and a stage.

  The question column holds the progress bar, the "Step N of 5" label, the
  step's heading and description, the step's own content and the Back and
  Continue row. The stage shows the host's booking page as it takes shape,
  in a `StageFrame`, on the theme's canvas colour.

  Markup order is the same at every size (question column first, then
  stage), so the reading and tab order never change; only the stylesheet
  (`onboarding.css`) moves them. From `lg` the column is a 440px panel on
  the left and the stage fills the rest at full height; below `lg` the stage
  is a card above the column and the Back and Continue row sticks to the
  bottom of the screen.

  ## Focus and announcements

    * **Heading focus.** Each step's heading has an id of its own, so a new
      step mounts a new heading. With `focus_heading` set, that heading takes
      the keyboard focus as it mounts, so a step change lands keyboard and
      screen-reader users at the start of the new step. The LiveView sets it
      after the host's first action, never for the page load.
    * **The live region.** The stage is decorative (`aria-hidden`). Whatever
      it shows that a host should hear about goes in the one polite live
      region in the question column: pass the sentence as
      `stage_announcement` (the LiveView's `@stage_announcement` assign).
      Assign a new sentence to announce it; `""` says nothing.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [action_button: 1, icon: 1]

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.OnboardingLive.StageFrame
  alias TymeslotWeb.OnboardingLive.StepConfig

  @doc """
  Renders the onboarding layout.

  ## Slots

  * `inner_block` - The step-specific content
  * `stage` - The page miniature, drawn at 400px wide; the stage scales it
  """
  attr :current_step, :atom, required: true
  attr :next_disabled, :boolean, default: false

  attr :booking_page_live, :boolean,
    default: true,
    doc: "whether the booking page accepts visitors, which changes how the final step reads"

  attr :focus_heading, :boolean,
    default: false,
    doc: "whether a newly mounted step heading takes the focus"

  attr :stage_announcement, :string,
    default: "",
    doc: "the sentence the live region announces"

  attr :stage_url, :string, required: true, doc: "the address the stage frame shows"
  attr :stage_live, :boolean, default: false, doc: "shows the Live badge on the stage"
  attr :stage_canvas, :string, required: true, doc: "the theme's canvas colour"
  attr :stage_theme, :string, default: nil, doc: "the id of the theme the stage draws"
  attr :stage_caption, :string, default: nil, doc: "a line under the stage frame"

  slot :inner_block, required: true
  slot :stage, required: true

  @spec onboarding_layout(map()) :: Phoenix.LiveView.Rendered.t()
  def onboarding_layout(assigns) do
    ~H"""
    <div class="onboarding-shell">
      <section
        class="onboarding-panel"
        aria-labelledby={"onboarding-step-heading-#{@current_step}"}
      >
        <div class="onboarding-panel-inner">
          <nav aria-label={dgettext("onboarding_wizard", "Setup progress")}>
            <ol class="onboarding-progress">
              <li
                :for={step <- StepConfig.steps()}
                class="onboarding-progress-segment"
                data-state={segment_state(step, @current_step)}
                aria-current={step == @current_step && "step"}
              >
                <span class="onboarding-progress-bar" />
                <span class="onboarding-progress-name">{StepConfig.progress_label(step)}</span>
              </li>
            </ol>
          </nav>

          <div class="onboarding-step-header">
            <p class="onboarding-step-label" data-role="onboarding-step-label">
              {dgettext("onboarding_wizard", "Step %{current} of %{total}",
                current: StepConfig.step_number(@current_step),
                total: StepConfig.step_count()
              )}
            </p>
            <h1
              id={"onboarding-step-heading-#{@current_step}"}
              class="onboarding-step-title"
              tabindex="-1"
              phx-mounted={@focus_heading && JS.focus()}
            >
              {StepConfig.step_title(@current_step)}
            </h1>
            <p class="onboarding-step-description">
              {StepConfig.step_description(@current_step, @booking_page_live)}
            </p>
          </div>

          <p class="sr-only" aria-live="polite" data-role="stage-announcement">
            {@stage_announcement}
          </p>

          <div id={"onboarding-step-#{@current_step}"} class="onboarding-slide-in-left">
            {render_slot(@inner_block)}
          </div>

          <div
            id="onboarding-nav"
            class="onboarding-nav"
            data-role="onboarding-nav"
            phx-hook="StickyNavClearance"
          >
            <.action_button
              :if={StepConfig.show_back_button?(@current_step)}
              variant={:ghost}
              icon="hero-arrow-left-mini"
              phx-click="previous_step"
            >
              {dgettext("onboarding_wizard", "Back")}
            </.action_button>

            <div class="onboarding-nav-spacer" />

            <.action_button
              variant={StepConfig.next_button_variant(@current_step)}
              phx-click="next_step"
              disabled={@next_disabled}
            >
              {StepConfig.next_button_text(@current_step)}
              <.icon name="hero-arrow-right-mini" class="w-5 h-5 shrink-0" />
            </.action_button>
          </div>
        </div>
      </section>

      <%!-- The canvas colour is known from the first paint, so the stage
           starts in the theme's colour rather than fading into it on every
           load; a theme change later recolours with the transition. --%>
      <div
        id="onboarding-stage"
        class="onboarding-stage"
        data-role="onboarding-stage"
        data-step={@current_step}
        data-theme={@stage_theme}
        data-stage-fit
        style={"--stage-canvas: #{@stage_canvas};"}
      >
        <StageFrame.frame url={@stage_url} live={@stage_live}>
          <StageFrame.scaled id="onboarding-stage-scale">
            {render_slot(@stage)}
          </StageFrame.scaled>
        </StageFrame.frame>
        <p :if={@stage_caption} class="onboarding-stage-caption text-token-sm">
          {@stage_caption}
        </p>
      </div>
    </div>
    """
  end

  defp segment_state(step, current_step) do
    cond do
      step == current_step -> "current"
      StepConfig.step_completed?(step, current_step) -> "done"
      true -> "upcoming"
    end
  end
end
