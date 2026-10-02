defmodule TymeslotWeb.Components.CoreComponents.Feedback do
  @moduledoc "Feedback/status components extracted from CoreComponents."
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.CoreComponents.Icons

  @pill_tones [:brand, :neutral, :success, :warning, :danger, :info]

  @pill_tone_classes %{
    brand: "bg-turquoise-100 text-turquoise-700",
    neutral: "bg-tymeslot-100 text-tymeslot-600",
    success: "bg-green-100 text-green-700",
    warning: "bg-amber-100 text-amber-700",
    danger: "bg-red-100 text-red-700",
    info: "bg-blue-100 text-blue-700"
  }

  @pill_dot_classes %{
    brand: "bg-turquoise-500",
    neutral: "bg-tymeslot-400",
    success: "bg-green-500",
    warning: "bg-amber-500",
    danger: "bg-red-500",
    info: "bg-blue-500"
  }

  @pill_size_classes %{
    xs: "gap-1 px-2 py-0.5",
    sm: "gap-1.5 px-3 py-1"
  }

  @pill_icon_classes %{xs: "w-3 h-3 shrink-0", sm: "w-3.5 h-3.5 shrink-0"}

  @empty_state_sizes [:sm, :md, :lg]
  @empty_state_variants [:card, :dashed, :plain]
  @empty_state_tones [:neutral, :brand, :warning]
  @empty_state_headings [:p, :h2, :h3]

  @empty_state_size_classes %{
    sm: %{
      box: "px-4 py-8",
      tile: "mb-3 h-12 w-12 rounded-token-xl",
      icon: "h-6 w-6",
      title: "text-token-base font-bold",
      description: "mt-1 text-token-sm",
      actions: "mt-4"
    },
    md: %{
      box: "px-6 py-12",
      tile: "mb-4 h-16 w-16 rounded-token-2xl",
      icon: "h-8 w-8",
      title: "text-token-lg font-black",
      description: "mt-1 text-token-sm",
      actions: "mt-6"
    },
    lg: %{
      box: "px-6 py-16 sm:py-20",
      tile: "mb-6 h-20 w-20 rounded-token-3xl",
      icon: "h-10 w-10",
      title: "text-token-2xl font-black",
      description: "mt-2 text-token-base",
      actions: "mt-8"
    }
  }

  # `tile` is the neutral tile's surface on each variant; a non-neutral tone
  # brings its own.
  @empty_state_variant_classes %{
    card: %{surface: "card-glass", tile: "bg-tymeslot-50 border-tymeslot-100"},
    dashed: %{
      surface: "rounded-token-2xl border-2 border-dashed border-tymeslot-200 bg-tymeslot-50/50",
      tile: "bg-white border-tymeslot-100 shadow-sm"
    },
    plain: %{surface: nil, tile: "bg-tymeslot-50 border-tymeslot-100"}
  }

  @empty_state_tone_classes %{
    neutral: %{tile: "text-tymeslot-400", title: "text-tymeslot-900"},
    brand: %{
      tile: "bg-turquoise-50 border-turquoise-100 text-turquoise-600",
      title: "text-tymeslot-900"
    },
    warning: %{tile: "bg-amber-50 border-amber-100 text-amber-600", title: "text-amber-700"}
  }

  # ========== FEEDBACK ==========

  @doc """
  Renders a loading spinner.
  """
  attr :class, :string, default: nil
  attr :rest, :global

  @spec spinner(map()) :: Phoenix.LiveView.Rendered.t()
  def spinner(assigns) do
    ~H"""
    <svg
      class={["spinner", @class || "h-5 w-5"]}
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      {@rest}
    >
      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
      </circle>
      <path
        class="opacity-75"
        fill="currentColor"
        d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
      >
      </path>
    </svg>
    """
  end

  @doc """
  Renders an empty state: an icon in a tile, a title, an optional
  description and optional actions, all centred.

      <.empty_state
        icon="hero-hand-raised"
        title={dgettext("dashboard_common", "No polls yet")}
        description={dgettext("dashboard_common", "Create a poll to ...")}
      >
        <:action>
          <.action_button phx-click="new_poll">New poll</.action_button>
        </:action>
      </.empty_state>

  `variant` picks the surface: `:card` stands alone as a glass card,
  `:dashed` marks a gap inside a card that already has content around it, and
  `:plain` draws no surface at all, for a slot that already sits in a card.
  `size` scales the tile and the type: `:lg` for a whole page that is empty,
  `:md` for a section, `:sm` for a panel or a list inside a card.

  `tone` colours the tile and the title: `:neutral` for most, `:brand` for a
  first-run invitation drawn with a brand mark, `:warning` for a state the
  organiser has to act on, such as an expired link. `heading` sets the title's
  element: keep `:p` inside a section, and pass `:h2` or `:h3` when the empty
  state stands in for a page or a section that would otherwise carry that
  heading.

  For a mark the hero set lacks (a brand logo), pass the `:graphic` slot
  instead of `icon`; it is drawn inside the same tile and inherits its colour.
  When both are given, only the graphic is drawn. The inner block, when given,
  renders below the actions, for supporting detail such as a hint or a
  fallback instruction.
  """
  attr :icon, :string, default: nil, doc: "A `hero-…` icon name shown in the tile"
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :size, :atom, default: :md, values: @empty_state_sizes
  attr :variant, :atom, default: :card, values: @empty_state_variants
  attr :tone, :atom, default: :neutral, values: @empty_state_tones
  attr :heading, :atom, default: :p, values: @empty_state_headings, doc: "The title's element"
  attr :class, :any, default: nil, doc: "Layout classes only"
  attr :rest, :global
  slot :graphic, doc: "Custom tile content, in place of `icon`; wins when both are given"
  slot :action, doc: "Buttons or links offering the way out of the empty state"
  slot :inner_block, doc: "Supporting detail below the actions"

  @spec empty_state(map()) :: Phoenix.LiveView.Rendered.t()
  def empty_state(assigns) do
    variant = Map.fetch!(@empty_state_variant_classes, assigns.variant)
    tone = Map.fetch!(@empty_state_tone_classes, assigns.tone)

    assigns =
      assign(assigns,
        sizing: Map.fetch!(@empty_state_size_classes, assigns.size),
        surface: variant.surface,
        tile_class: [assigns.tone == :neutral && variant.tile, tone.tile],
        title_class: tone.title,
        heading_tag: Atom.to_string(assigns.heading)
      )

    ~H"""
    <div class={["text-center", @surface, @sizing.box, @class]} {@rest}>
      <div
        :if={@icon || @graphic != []}
        class={[
          "mx-auto flex items-center justify-center border-2",
          @tile_class,
          @sizing.tile
        ]}
        aria-hidden="true"
      >
        <Icons.icon :if={@icon && @graphic == []} name={@icon} class={@sizing.icon} />
        {render_slot(@graphic)}
      </div>
      <.dynamic_tag tag_name={@heading_tag} class={["tracking-tight", @title_class, @sizing.title]}>
        {@title}
      </.dynamic_tag>
      <p
        :if={@description}
        class={["mx-auto max-w-md font-medium leading-relaxed text-tymeslot-500", @sizing.description]}
      >
        {@description}
      </p>
      <div
        :if={@action != []}
        class={["flex flex-wrap items-center justify-center gap-3", @sizing.actions]}
      >
        {render_slot(@action)}
      </div>
      <div :if={@inner_block != []} class={@sizing.actions}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a card holding a centred spinner, standing in for content that is
  still loading. `label` is announced to screen readers.
  """
  attr :label, :string, default: nil, doc: "Screen reader text; defaults to \"Loading\""
  attr :class, :any, default: nil, doc: "Layout classes only"
  attr :rest, :global

  @spec loading_card(map()) :: Phoenix.LiveView.Rendered.t()
  def loading_card(assigns) do
    ~H"""
    <div class={["card-glass", @class]} role="status" {@rest}>
      <div class="flex items-center justify-center py-12">
        <.spinner class="h-8 w-8 text-turquoise-600" aria-hidden="true" />
        <span class="sr-only">{@label || dgettext("common", "Loading")}</span>
      </div>
    </div>
    """
  end

  @doc """
  Renders a small status pill: a rounded label in one of six tones.

  `icon` puts a `hero-…` icon before the label; `dot` puts a small status dot
  there instead, and `pulse` animates that dot (for something happening now;
  it stops when the visitor prefers reduced motion).

  Case rule: labels are sentence case by default, which suits multi-word
  phrases and data such as a timezone, a count or an HTTP status. Pass
  `uppercase` for one-word tags ("Booking", "Pro"). Pick one case per
  surface: a wrapper opts in only when every label it can show is a single
  word, so neighbouring pills never mix.

  `class` is for layout only (margins, alignment); colour and type come from
  `tone` and `size`, so every pill in the dashboard reads the same.
  """
  attr :tone, :atom, default: :neutral, values: @pill_tones
  attr :size, :atom, default: :xs, values: [:xs, :sm]
  attr :icon, :string, default: nil, doc: "A `hero-…` icon name shown before the label"
  attr :dot, :boolean, default: false, doc: "Show a status dot before the label"
  attr :pulse, :boolean, default: false, doc: "Show an animated dot (implies `dot`)"

  attr :uppercase, :boolean,
    default: false,
    doc: "Uppercase the label; for one-word tags only, never phrases or data"

  attr :class, :any, default: nil, doc: "Layout classes only"
  attr :rest, :global
  slot :inner_block, required: true

  @spec pill(map()) :: Phoenix.LiveView.Rendered.t()
  def pill(assigns) do
    assigns =
      assign(assigns,
        tone_class: Map.fetch!(@pill_tone_classes, assigns.tone),
        size_class: Map.fetch!(@pill_size_classes, assigns.size),
        icon_class: Map.fetch!(@pill_icon_classes, assigns.size),
        dot_class: (assigns.dot or assigns.pulse) && pill_dot_class(assigns.tone)
      )

    ~H"""
    <span
      class={[
        "inline-flex shrink-0 items-center rounded-token-full text-token-xs font-black tabular-nums",
        @uppercase && "uppercase tracking-wider",
        @size_class,
        @tone_class,
        @class
      ]}
      {@rest}
    >
      <Icons.icon :if={@icon} name={@icon} class={@icon_class} />
      <span
        :if={!@icon && @dot_class}
        class={["w-1.5 h-1.5 shrink-0 rounded-token-full", @dot_class, @pulse && "animate-pulse"]}
        aria-hidden="true"
      ></span>
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  The background class of a pill's status dot for `tone`, for a bare status
  dot that has to match the pills beside it.
  """
  @spec pill_dot_class(atom()) :: String.t()
  def pill_dot_class(tone), do: Map.fetch!(@pill_dot_classes, tone)
end
