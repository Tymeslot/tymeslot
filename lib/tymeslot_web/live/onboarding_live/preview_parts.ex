defmodule TymeslotWeb.OnboardingLive.PreviewParts do
  @moduledoc """
  Building blocks for the onboarding wizard's theme previews.

  The wizard shows a booking theme twice: as a thumbnail on the theme step's
  picker, and as the live preview card beside every step. How a theme looks
  there is the theme's own `onboarding_preview/1`; this module holds what
  those implementations share: `theme_preview/1` (the one entry point the
  wizard renders), the generic mock for a theme that draws none, the
  per-user colour style builders, and the slot and Book-button pieces.

  Per-user colours come from the theme's resolved customisation tokens
  (`colors/1`) and are applied through inline `style`; structural layout is
  Tailwind utilities.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  alias Tymeslot.ThemeCustomizations.Tokens

  attr :theme_module, :atom, required: true
  attr :variant, :atom, values: [:thumbnail, :card], required: true
  attr :primary, :string, default: nil, doc: "`:thumbnail`: the theme's primary colour"
  attr :colors, :map, default: %{}, doc: "`:card`: the colour map from `colors/1`"
  attr :slots, :list, default: [], doc: "`:card`: `%{label, state, check}` sample slots"
  attr :locale, :string, default: "en"
  attr :highlight_card, :boolean, default: false
  attr :highlight_slots, :boolean, default: false
  slot :header, doc: "`:card`: the shared identity header the theme draws its card around"

  @doc """
  Renders a theme's onboarding preview through its `onboarding_preview/1`,
  or the generic mock for a module that does not implement it.
  """
  @spec theme_preview(map()) :: Phoenix.LiveView.Rendered.t()
  def theme_preview(assigns) do
    module = assigns.theme_module

    if Code.ensure_loaded?(module) and function_exported?(module, :onboarding_preview, 1) do
      module.onboarding_preview(assigns)
    else
      generic(assigns)
    end
  end

  @doc "The generic mock: a plain card with a slot grid and a solid Book button."
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
      style={card_style(@colors, @highlight_card)}
    >
      {render_slot(@header)}
      <div class="grid grid-cols-2 gap-1.5 w-full" style={slots_style(@highlight_slots)}>
        <.slot_chip :for={slot <- @slots} colors={@colors} slot={slot} />
      </div>
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

  attr :colors, :map, required: true
  attr :slot, :map, required: true

  @doc "A slot as a chip, for grid layouts."
  @spec slot_chip(map()) :: Phoenix.LiveView.Rendered.t()
  def slot_chip(assigns) do
    ~H"""
    <span
      class="text-token-xs px-2 py-1.5 rounded-token-md font-medium inline-flex items-center justify-center gap-1"
      style={slot_style(@colors, @slot.state)}
    >
      <.icon :if={@slot.check} name="hero-check-mini" class="w-3 h-3" />
      {@slot.label}
    </span>
    """
  end

  attr :colors, :map, required: true
  attr :slot, :map, required: true

  @doc "A slot as a full-width row, for list layouts."
  @spec slot_row(map()) :: Phoenix.LiveView.Rendered.t()
  def slot_row(assigns) do
    ~H"""
    <span
      class="text-token-xs px-3 py-2 rounded-token-md font-medium w-full inline-flex items-center gap-1.5"
      style={slot_style(@colors, @slot.state)}
    >
      <.icon :if={@slot.check} name="hero-check-mini" class="w-3 h-3" />
      {@slot.label}
    </span>
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

  @spec card_style(map(), boolean()) :: String.t()
  def card_style(colors, highlighted?) do
    "background: #{color(colors, :surface, "#ffffff")};color: #{color(colors, :text, "#0f172a")};" <>
      ring(highlighted?, colors)
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

  # A few cells get the primary tint to read as "available days".
  @spec calendar_cell_style(map(), integer()) :: String.t()
  def calendar_cell_style(colors, day) when day in [4, 9, 12, 17] do
    "background: #{color(colors, :primary, "#14b8a6")};"
  end

  def calendar_cell_style(colors, _day) do
    "background: #{color(colors, :primary, "#14b8a6")}14;"
  end

  @spec week_cell_style(map(), boolean()) :: String.t()
  def week_cell_style(colors, true) do
    "background: #{color(colors, :primary, "#14b8a6")};color: #ffffff;"
  end

  def week_cell_style(colors, false) do
    "background: #{color(colors, :primary, "#14b8a6")}14;color: #{color(colors, :text_secondary, "#475569")};"
  end

  @spec slots_style(boolean()) :: String.t()
  def slots_style(highlighted?) do
    if highlighted?, do: "opacity: 1;", else: ""
  end

  @spec slot_style(map(), atom()) :: String.t()
  def slot_style(colors, :muted) do
    "background: #{color(colors, :text_secondary, "#475569")}1f;color: #{color(colors, :text_secondary, "#475569")};opacity: 0.5;"
  end

  def slot_style(colors, :filled) do
    "background: #{color(colors, :primary, "#14b8a6")}26;color: #{color(colors, :primary, "#14b8a6")};"
  end

  def slot_style(colors, _state) do
    "background: #{color(colors, :primary, "#14b8a6")}14;color: #{color(colors, :text, "#0f172a")};"
  end

  @spec ring(boolean(), map()) :: String.t()
  def ring(false, _colors), do: ""

  def ring(true, colors) do
    "box-shadow: 0 0 0 3px #{color(colors, :primary, "#14b8a6")};"
  end
end
