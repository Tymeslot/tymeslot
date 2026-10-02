defmodule TymeslotWeb.Components.CoreComponents.Feedback do
  @moduledoc "Feedback/status components extracted from CoreComponents."
  use Phoenix.Component

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

  # ========== FEEDBACK ==========

  @doc """
  Renders a loading spinner.
  """
  attr :class, :string, default: nil

  @spec spinner(map()) :: Phoenix.LiveView.Rendered.t()
  def spinner(assigns) do
    ~H"""
    <svg
      class={["spinner", @class || "h-5 w-5"]}
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
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
  Renders an empty state display.
  """
  attr :message, :string, required: true
  attr :secondary_message, :string, default: nil
  slot :icon, required: true

  @spec empty_state(map()) :: Phoenix.LiveView.Rendered.t()
  def empty_state(assigns) do
    ~H"""
    <div class="h-full flex items-center justify-center">
      <div class="text-center p-4">
        <svg
          class="w-12 h-12 mx-auto mb-2 text-tymeslot-400"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          {render_slot(@icon)}
        </svg>
        <p class="text-sm font-medium" style="color: rgba(255,255,255,0.8);">
          {@message}
        </p>
        <%= if @secondary_message do %>
          <p class="text-xs mt-1" style="color: rgba(255,255,255,0.6);">
            {@secondary_message}
          </p>
        <% end %>
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
