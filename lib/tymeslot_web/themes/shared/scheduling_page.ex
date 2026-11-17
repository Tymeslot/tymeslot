defmodule TymeslotWeb.Themes.Shared.SchedulingPage do
  @moduledoc """
  The page a scheduling theme renders: its wrapper around what its journey
  shows.

  `SchedulingLive` generates each theme's `render/1` from this, given the
  theme's wrapper component and journey (`Shared.Journey`), so every theme
  handles the same states the same way: a readiness or error message in place
  of the booking; for an outcome (`:confirmation`, `:awaiting_payment`) its
  component, or the shared awaiting-payment screen when the journey's
  `awaiting_payment` is `:shared`; otherwise each moment the journey's
  navigator makes visible (`Navigator.visible/2`), which for a state the
  journey does not know is its first moment. The visible moments sit in the
  navigator's frame (`Journey.Components.frame/1`); a paged journey's one
  moment is rendered bare.

  A component gets the id `"<key>-step"` (the ids every theme's hand-written
  render used, which tests and CSS rely on) and the LiveView's assigns minus
  this module's own. A moment's component also gets `moment`, its key, and
  `moment_state`, `:current`, `:done` or `:open`; an outcome's gets neither.
  The assigns a component may rely on are the table in
  `docs/THEME_DEVELOPMENT_GUIDE.md` §"Step Components".

  On a demo page the shared theme switcher (`Components.DemoThemeSwitcher`)
  leads the content, above the moments, so every theme carries it without a
  wrapper of its own changing.
  """

  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.Components.{AwaitingPayment, DemoThemeSwitcher, ErrorComponent}
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
  alias TymeslotWeb.Themes.Shared.PathHandlers

  @page_keys [:page_wrapper, :page_parts, :page_navigator]

  @doc "Renders `wrapper` around the outcome or the visible moments of `journey`."
  @spec render(map(), (map() -> Phoenix.LiveView.Rendered.t()), Journey.t()) ::
          Phoenix.LiveView.Rendered.t()
  def render(assigns, wrapper, journey) do
    assigns =
      assign(assigns,
        page_wrapper: wrapper,
        page_parts: parts(journey, assigns),
        page_navigator: journey.navigator
      )

    ~H"""
    <.wrapper
      wrapper={@page_wrapper}
      theme_tokens={assigns[:theme_tokens]}
      locale={assigns[:locale]}
      offered_locales={assigns[:offered_locales]}
      language_dropdown_open={assigns[:language_dropdown_open]}
      current_state={assigns[:current_state]}
      journey={assigns[:journey]}
      organizer_user_id={@organizer_user_id}
      owner_preview={assigns[:owner_preview]}
      refused_calendars={assigns[:refused_calendars] || []}
      should_show_branding={branding(assigns)}
      legal_links={assigns[:legal_links]}
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
        <% @page_parts == :awaiting_payment -> %>
          <AwaitingPayment.awaiting_payment checkout_url={@awaiting_payment_checkout_url} />
        <% true -> %>
          <JourneyComponents.frame navigator={@page_navigator}>
            <.live_component
              :for={{module, id, extra} <- @page_parts}
              module={module}
              id={id}
              {step_assigns(assigns, extra)}
            />
          </JourneyComponents.frame>
      <% end %>
    </.wrapper>
    """
  end

  # The page's owner previewing it (a verified preview token) is not a
  # visitor to win over, so their preview never carries the branding
  # extension's invitation to make a page of their own.
  defp branding(%{owner_preview: true}), do: false
  defp branding(assigns), do: assigns[:should_show_branding]

  # The documented dynamic-component pattern: the theme's wrapper is a
  # function component chosen at runtime, so it is applied directly.
  defp wrapper(assigns) do
    {wrapper, assigns} = Map.pop(assigns, :wrapper)
    wrapper.(assigns)
  end

  # What the page shows: `:awaiting_payment` for the shared payment screen,
  # else `{component, id, extra assigns}` for each component, the outcome's
  # or the visible moments'.
  defp parts(journey, assigns) do
    state = assigns[:current_state]

    case Map.fetch(journey.outcomes, state) do
      {:ok, :shared} ->
        :awaiting_payment

      {:ok, component} ->
        [{component, "#{state}-step", %{}}]

      :error ->
        for {moment, moment_state} <- journey.navigator.visible(journey, assigns),
            do:
              {moment.component, "#{moment.key}-step",
               %{moment: moment.key, moment_state: moment_state}}
    end
  end

  defp step_assigns(assigns, extra), do: assigns |> Map.drop(@page_keys) |> Map.merge(extra)
end
