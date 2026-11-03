defmodule TymeslotWeb.OnboardingLive.PreviewParts do
  @moduledoc """
  Building blocks for the onboarding wizard's theme previews.

  The wizard shows a booking theme twice: as a thumbnail on the theme step's
  picker, and as the live preview card beside every step. How a theme looks
  there is the theme's own `onboarding_preview/1`; this module holds what
  those implementations share: `theme_preview/1` (the one entry point the
  wizard renders), the generic mock for a theme that draws none, the
  per-user colour style builders and the Book button. The week a card
  shows, and the parts that draw it, are `PreviewWeek`'s.

  Per-user colours come from the theme's resolved customisation tokens
  (`colors/1`) and are applied through inline `style`; structural layout is
  Tailwind utilities.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.ThemeCustomizations.Tokens
  alias TymeslotWeb.OnboardingLive.PreviewWeek

  attr :theme_module, :atom, required: true
  attr :variant, :atom, values: [:thumbnail, :card], required: true
  attr :primary, :string, default: nil, doc: "`:thumbnail`: the theme's primary colour"
  attr :colors, :map, default: %{}, doc: "`:card`: the colour map from `colors/1`"

  attr :week, :map,
    default: nil,
    doc:
      "`:card`: the stage's week, `%{state, preview}` (`PreviewWeek`); `nil` is the placeholder"

  attr :today, :any, default: nil, doc: "`:card`: today in the host's timezone (default: UTC)"
  attr :locale, :string, default: "en"
  attr :reveal, :boolean, default: false, doc: "`:card`: play the times' reveal on this render"

  attr :highlight, :list,
    default: [],
    doc: "`:card`: the regions ringed for the current step: `:calendar`, `:slots`"

  slot :header, doc: "`:card`: the shared identity header the theme draws its card around"

  @doc """
  Renders a theme's onboarding preview through its `onboarding_preview/1`,
  or the generic mock for a module that does not implement it.

  For the `:card` it adds `view`, the week as `PreviewWeek.view/3` resolves
  it, which is all a theme reads about the week.
  """
  @spec theme_preview(map()) :: Phoenix.LiveView.Rendered.t()
  def theme_preview(assigns) do
    module = assigns.theme_module
    assigns = with_view(assigns)

    if Code.ensure_loaded?(module) and function_exported?(module, :onboarding_preview, 1) do
      module.onboarding_preview(assigns)
    else
      generic(assigns)
    end
  end

  defp with_view(%{variant: :card} = assigns) do
    today = assigns.today || Date.utc_today()
    assign(assigns, :view, PreviewWeek.view(assigns.week, today, assigns.locale))
  end

  defp with_view(assigns), do: assigns

  @doc "The generic mock: a plain card with a week strip, the chosen day and a solid Book button."
  @spec generic(map()) :: Phoenix.LiveView.Rendered.t()
  def generic(%{variant: :thumbnail} = assigns) do
    ~H"""
    <div class="aspect-[4/3] w-full rounded-token-lg bg-tymeslot-900 p-2 flex flex-col gap-1.5 overflow-hidden">
      <div class="h-1.5 w-2/3 rounded-full bg-white/30" />
      <div class="grid grid-cols-2 gap-1">
        <span :for={_n <- 1..4} class="h-2.5 rounded-token-sm" style={"background: #{@primary};"} />
      </div>
    </div>
    """
  end

  def generic(%{variant: :card} = assigns) do
    ~H"""
    <div
      class="rounded-token-2xl p-5 flex flex-col items-center gap-3"
      style={card_style(@colors)}
    >
      {render_slot(@header)}
      <PreviewWeek.calendar_area colors={@colors} highlight={@highlight} class="flex flex-col gap-2">
        <PreviewWeek.day_strip view={@view} colors={@colors} />
        <PreviewWeek.times
          view={@view}
          colors={@colors}
          layout={:rows}
          limit={5}
          class="flex flex-col gap-1.5"
          reveal={@reveal}
          highlight={@highlight}
        />
      </PreviewWeek.calendar_area>
      <.book_button
        class="w-full py-2 rounded-token-lg font-semibold text-white text-token-sm mt-1"
        style={"background: #{color(@colors, :primary, "#14b8a6")};"}
      />
    </div>
    """
  end

  attr :class, :string, required: true
  attr :style, :string, required: true

  @doc "The disabled Book button every preview card ends with."
  @spec book_button(map()) :: Phoenix.LiveView.Rendered.t()
  def book_button(assigns) do
    ~H"""
    <button type="button" class={@class} style={@style} disabled>
      {dgettext("onboarding_wizard", "Book")}
    </button>
    """
  end

  # Colour -> the custom property a spec's `tokens/2` resolves it to. These
  # are the colours the previews draw with; one the theme's tokens leave out
  # falls back to the neutral default at each use (`color/3`).
  @preview_vars %{
    primary: "--theme-primary",
    accent: "--theme-accent",
    background: "--theme-canvas",
    surface: "--theme-surface",
    text: "--theme-text",
    text_secondary: "--theme-text-secondary"
  }

  @doc "The colour map the previews draw with, read from a theme's resolved tokens."
  @spec colors(Tokens.t()) :: %{optional(atom()) => String.t()}
  def colors(%Tokens{vars: vars}) do
    for {key, var} <- @preview_vars, Map.has_key?(vars, var), into: %{}, do: {key, vars[var]}
  end

  @spec color(map(), atom(), String.t()) :: String.t()
  def color(colors, key, fallback), do: Map.get(colors, key) || fallback

  @spec card_style(map()) :: String.t()
  def card_style(colors) do
    "background: #{color(colors, :surface, "#ffffff")};color: #{color(colors, :text, "#0f172a")};"
  end

  @spec divider_style(map()) :: String.t()
  def divider_style(colors) do
    "background: #{color(colors, :text_secondary, "#475569")}26;"
  end

  @spec step_dot_style(map(), boolean()) :: String.t()
  def step_dot_style(colors, true) do
    "background: #{color(colors, :primary, "#14b8a6")};color: #ffffff;"
  end

  def step_dot_style(colors, false) do
    "background: #{color(colors, :primary, "#14b8a6")}1f;color: #{color(colors, :text_secondary, "#475569")};"
  end

  @doc """
  The step highlight: an outline in the primary colour a little outside a
  region, or nothing.
  """
  @spec ring(boolean(), map()) :: String.t()
  def ring(false, _colors), do: ""

  def ring(true, colors) do
    "outline: 2px solid #{color(colors, :primary, "#14b8a6")};outline-offset: 4px;"
  end
end
