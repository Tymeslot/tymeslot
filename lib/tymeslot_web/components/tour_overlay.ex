defmodule TymeslotWeb.Components.TourOverlay do
  @moduledoc """
  Renders the dimming overlay, spotlight, and tooltip card for the
  post-onboarding dashboard tour.

  Step content is driven from `Tymeslot.Onboarding.DashboardTour`. Positioning
  is handled by the `DashboardTour` JS hook. The server owns step-index state
  and dispatches `tour:*` events to the parent LiveView.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  @impl Phoenix.LiveComponent
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div
      id="dashboard-tour"
      class="dashboard-tour"
      phx-hook="DashboardTour"
      phx-remove={JS.transition("dashboard-tour--leaving", time: 700)}
      data-anchor={@step.anchor}
      data-placement={Atom.to_string(@step.placement)}
      data-step-index={@step_index}
      data-total-steps={@total_steps}
    >
      <%!-- Dim backdrop + spotlight cut-out are positioned by JS. --%>
      <div class="dashboard-tour__backdrop" aria-hidden="true"></div>
      <div class="dashboard-tour__spotlight" aria-hidden="true"></div>

      <div
        class="dashboard-tour__tooltip"
        role="dialog"
        aria-modal="false"
        aria-labelledby="dashboard-tour-title"
      >
        <p class="dashboard-tour__progress">
          {dgettext("onboarding", "Step %{n} of %{total}", n: @step_index + 1, total: @total_steps)}
        </p>
        <h2 id="dashboard-tour-title" class="dashboard-tour__title">{@step.title}</h2>
        <p class="dashboard-tour__body">{@step.body}</p>

        <div class="dashboard-tour__actions">
          <.action_button variant={:outline} phx-click="tour:skip">
            {dgettext("onboarding", "Skip")}
          </.action_button>

          <div class="dashboard-tour__spacer"></div>

          <.action_button :if={@step_index > 0} variant={:secondary} phx-click="tour:back">
            {dgettext("onboarding", "Back")}
          </.action_button>

          <.action_button
            :if={@step_index < @total_steps - 1}
            variant={:primary}
            phx-click="tour:next"
          >
            {dgettext("onboarding", "Next")}
          </.action_button>

          <.action_button
            :if={@step_index == @total_steps - 1}
            variant={:primary}
            phx-click="tour:finish"
          >
            {dgettext("onboarding", "Finish")}
          </.action_button>
        </div>
      </div>
    </div>
    """
  end
end
