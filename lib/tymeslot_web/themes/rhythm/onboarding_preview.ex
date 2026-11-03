defmodule TymeslotWeb.Themes.Rhythm.OnboardingPreview do
  @moduledoc """
  Rhythm in the onboarding wizard: atmosphere first. As on the real page,
  the host's background runs edge to edge behind a frosted glass card, and
  a pause control in the corner says it moves. The card carries the week as
  a strip of outlined day tiles with uppercase names, the chosen day's times
  as compact rows (busy blocks hatched between them), and Rhythm's Back and
  Book pair.

  The background is a still: a video background shows its poster, never the
  video, so the stage costs no data or battery on a phone. A background
  with no picture (a colour, a gradient, or none) shows the palette's canvas
  under a soft glow of the primary colour.
  """
  use Phoenix.Component

  use TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  import TymeslotWeb.OnboardingLive.PreviewParts, only: [book_button: 1, color: 3]

  alias Tymeslot.ThemeCustomizations.Presets
  alias TymeslotWeb.OnboardingLive.PreviewWeek

  # The still the thumbnail shows: Rhythm's own default background.
  @thumbnail_poster "rhythm-background-poster.jpg"

  @doc "Draws the `:thumbnail` or `:card` variant; see `Behaviour.onboarding_preview/1`."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(%{variant: :thumbnail} = assigns), do: thumbnail(assigns)
  def render(%{variant: :card} = assigns), do: card(assigns)

  attr :primary, :string, required: true

  @spec thumbnail(map()) :: Phoenix.LiveView.Rendered.t()
  def thumbnail(assigns) do
    assigns = assign(assigns, :poster, Presets.video_poster_url(@thumbnail_poster))

    ~H"""
    <div
      class="aspect-[4/3] w-full rounded-token-lg p-2 flex items-center justify-center overflow-hidden bg-tymeslot-900 bg-cover bg-center"
      style={"background-image: url('#{@poster}');"}
      data-preview="rhythm"
      data-preview-part="backdrop"
    >
      <div class="w-3/4 rounded-token-md p-1.5 flex flex-col gap-1 bg-black/35 border border-white/20 backdrop-blur-glass-light">
        <div class="h-1 w-1/2 rounded-full bg-white/50" />
        <div class="grid grid-cols-5 gap-0.5">
          <span :for={_day <- 1..5} class="h-2 rounded-token-sm border border-white/25" />
        </div>
        <span class="h-1.5 w-2/3 rounded-full" style={"background: #{@primary};"} />
      </div>
    </div>
    """
  end

  attr :colors, :map, required: true
  attr :background, :map, default: nil, doc: "the page background (`Tokens.media.background`)"
  attr :view, :map, required: true, doc: "the week, from `PreviewWeek.view/3`"
  attr :highlight, :list, default: []
  slot :header, required: true

  @doc "Rhythm's glass card over the host's background."
  @spec card(map()) :: Phoenix.LiveView.Rendered.t()
  def card(assigns) do
    assigns = assign(assigns, :still, still(assigns.background))

    ~H"""
    <div class="relative" data-preview="rhythm">
      <%!-- The background bleeds past the miniature's own padding to the
           stage's edges; the stage clips it. --%>
      <div
        class="absolute -inset-y-6 -inset-x-80 pointer-events-none bg-cover bg-center"
        style={backdrop_style(@colors, @still)}
        data-preview-part="backdrop"
      />
      <div
        class="relative rounded-token-xl p-5 flex flex-col items-center gap-3 border backdrop-blur-glass-medium"
        style={glass_style(@colors)}
      >
        {render_slot(@header)}
        <PreviewWeek.calendar_area colors={@colors} highlight={@highlight}>
          <p
            class="w-full text-center text-token-xs font-semibold"
            style={"color: #{color(@colors, :text, "#e2e8f0")};"}
          >
            {@view.month.title}
          </p>
          <PreviewWeek.day_strip
            view={@view}
            colors={@colors}
            cell_class="rounded-token-md border border-white/15 uppercase tracking-wide"
          />
          <PreviewWeek.times
            view={@view}
            colors={@colors}
            layout={:rows}
            limit={4}
            class="flex flex-col gap-1.5"
            item_class="rounded-token-md border border-white/10"
            highlight={@highlight}
          />
        </PreviewWeek.calendar_area>
        <div class="w-full grid grid-cols-[auto_1fr] gap-2 mt-1">
          <span class="px-3 inline-flex items-center rounded-token-lg border border-white/20 text-white/80">
            <.icon name="hero-arrow-left-mini" class="w-4 h-4" />
          </span>
          <.book_button
            class="py-2 rounded-token-lg font-semibold text-token-sm"
            style={book_style(@colors)}
          />
        </div>
      </div>
      <%!-- The real page's pause control: this background moves. --%>
      <span
        :if={match?(%{kind: :video}, @background)}
        class="absolute -bottom-3 -left-3 w-7 h-7 rounded-full inline-flex items-center justify-center bg-black/60 text-white"
        data-preview-part="motion-toggle"
      >
        <.icon name="hero-pause-micro" class="w-3.5 h-3.5" />
      </span>
    </div>
    """
  end

  # The still behind the card: a video's poster or an image, else none.
  defp still(%{kind: :video, poster: poster}) when is_binary(poster), do: poster
  defp still(%{kind: :image, url: url}) when is_binary(url), do: url
  defp still(_background), do: nil

  defp backdrop_style(colors, nil) do
    canvas = color(colors, :background, "#0f172a")
    primary = color(colors, :primary, "#06b6d4")

    "background: radial-gradient(60% 50% at 50% 35%, #{primary}40, transparent 70%), #{canvas};"
  end

  # A shade over the still keeps the card's text readable on a light frame.
  defp backdrop_style(colors, still) do
    "background-color: #{color(colors, :background, "#0f172a")};" <>
      "background-image: linear-gradient(rgba(0,0,0,0.3), rgba(0,0,0,0.45)), url('#{still}');"
  end

  defp glass_style(colors) do
    surface = color(colors, :surface, "#1e293b")

    "background: color-mix(in srgb, #{surface} 55%, transparent);" <>
      "border-color: rgba(255,255,255,0.18);color: #{color(colors, :text, "#e2e8f0")};"
  end

  defp book_style(colors) do
    "background: #{color(colors, :primary, "#06b6d4")};color: #ffffff;"
  end
end
