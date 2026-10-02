defmodule TymeslotWeb.Themes.Shared.SchedulingPage do
  @moduledoc """
  The page a scheduling theme renders: its wrapper around the current step.

  `SchedulingLive` generates each theme's `render/1` from this, given the
  theme's wrapper component and step components, so every theme handles the
  same states the same way: a readiness or error message in place of the
  flow, the step component for `:current_state`, the shared awaiting-payment
  screen, and the overview for a state it does not recognise.

  Each step component receives the LiveView's assigns minus this module's
  own; the ones a step may rely on are the table in
  `docs/THEME_DEVELOPMENT_GUIDE.md` §"Step Components".

  On a demo page the shared theme switcher (`Components.DemoThemeSwitcher`)
  leads the content, above the step, so every theme carries it without a
  wrapper of its own changing.
  """

  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.Components.{AwaitingPayment, DemoThemeSwitcher, ErrorComponent}
  alias TymeslotWeb.Themes.Shared.PathHandlers

  @page_keys [:page_wrapper, :step_module, :step_id]

  @doc "Renders `wrapper` around the step component `steps` holds for `:current_state`."
  @spec render(map(), (map() -> Phoenix.LiveView.Rendered.t()), %{atom() => module()}) ::
          Phoenix.LiveView.Rendered.t()
  def render(assigns, wrapper, steps) do
    {step_module, step_id} = step_component(steps, assigns[:current_state] || :overview)
    assigns = assign(assigns, page_wrapper: wrapper, step_module: step_module, step_id: step_id)

    ~H"""
    <.wrapper
      wrapper={@page_wrapper}
      theme_tokens={assigns[:theme_tokens]}
      locale={assigns[:locale]}
      language_dropdown_open={assigns[:language_dropdown_open]}
      current_state={assigns[:current_state]}
      organizer_user_id={@organizer_user_id}
      owner_preview={assigns[:owner_preview]}
      should_show_branding={assigns[:should_show_branding]}
      {Map.take(assigns, [:demo_mode])}
    >
      <DemoThemeSwitcher.switcher
        :if={assigns[:demo_theme_switcher]}
        theme_id={assigns[:theme_id]}
        base_path={PathHandlers.current_base_path(assigns)}
      />
      <%= cond do %>
        <% assigns[:scheduling_error_message] -> %>
          <.live_component
            module={ErrorComponent}
            id="scheduling-error"
            message={@scheduling_error_message}
          />
        <% assigns[:current_state] == :awaiting_payment -> %>
          <AwaitingPayment.awaiting_payment checkout_url={@awaiting_payment_checkout_url} />
        <% true -> %>
          <.live_component module={@step_module} id={@step_id} {step_assigns(assigns)} />
      <% end %>
    </.wrapper>
    """
  end

  # The documented dynamic-component pattern: the theme's wrapper is a
  # function component chosen at runtime, so it is applied directly.
  defp wrapper(assigns) do
    {wrapper, assigns} = Map.pop(assigns, :wrapper)
    wrapper.(assigns)
  end

  # Unknown states fall back to the overview, as every theme's hand-written
  # render did; the ids are the ones those renders used, which tests and CSS
  # rely on.
  defp step_component(steps, state) do
    case Map.fetch(steps, state) do
      {:ok, module} -> {module, "#{state}-step"}
      :error -> {Map.fetch!(steps, :overview), "overview-step"}
    end
  end

  defp step_assigns(assigns), do: Map.drop(assigns, @page_keys)
end
