defmodule TymeslotWeb.Themes.Folio.OnboardingPreview do
  @moduledoc """
  Folio in the onboarding wizard: a light page with a cover strip, the
  portrait overlapping it above the organiser's name and, once they have
  written one, their headline in a serif italic, then a month calendar
  of the host's coming week and the chosen day's times, the editorial shape
  of the real page. The Book button's ink
  is white where it reads on the primary, otherwise the scheme's dark
  colour (the gold primaries of the dark schemes). On a phone it takes the
  slim masthead of Folio's narrow page, a smaller portrait half over a
  shorter band with the name beside it, and shorter day cells.
  """
  use Phoenix.Component

  alias Tymeslot.Utils.Colour
  alias TymeslotWeb.OnboardingLive.PreviewWeek

  import TymeslotWeb.OnboardingLive.PreviewParts,
    only: [book_button: 1, card_style: 1, color: 3]

  @doc "Draws the `:thumbnail` or `:card` variant; see `Behaviour.onboarding_preview/1`."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(%{variant: :thumbnail} = assigns), do: thumbnail(assigns)
  def render(%{variant: :card} = assigns), do: card(assigns)

  attr :primary, :string, required: true

  @spec thumbnail(map()) :: Phoenix.LiveView.Rendered.t()
  def thumbnail(assigns) do
    ~H"""
    <div class="aspect-[4/3] w-full rounded-token-lg bg-tymeslot-50 p-2 overflow-hidden">
      <div class="h-full w-full rounded-token-md bg-white overflow-hidden flex flex-col">
        <span
          class="h-1/3 w-full"
          data-folio-cover
          style={"background: color-mix(in srgb, #{@primary} 40%, white);"}
        />
        <div class="flex-1 px-2 pb-2 flex flex-col gap-1">
          <span
            class="-mt-2 w-4 h-4 rounded-full border-2 border-white"
            style={"background: #{@primary};"}
          />
          <span class="h-1.5 w-1/2 rounded-full bg-tymeslot-300" />
          <span :for={_card <- 1..2} class="h-2 w-full rounded-token-sm border border-tymeslot-200" />
        </div>
      </div>
    </div>
    """
  end

  attr :colors, :map, required: true
  attr :view, :map, required: true, doc: "the week, from `PreviewWeek.view/3`"
  attr :highlight, :list, default: []
  slot :header, required: true

  @spec card(map()) :: Phoenix.LiveView.Rendered.t()
  def card(assigns) do
    assigns =
      assign(assigns,
        primary: color(assigns.colors, :primary, "#b4532a"),
        accent: color(assigns.colors, :accent, "#a0612f"),
        ink: ink(assigns.colors)
      )

    ~H"""
    <div class="rounded-token-2xl overflow-hidden flex flex-col" style={card_style(@colors)}>
      <span
        class="h-14 max-sm:h-8 w-full"
        data-folio-cover
        style={"background: linear-gradient(135deg, #{@primary}, #{@accent});"}
      />
      <div class="px-5 pb-5 flex flex-col items-center gap-3">
        <%!-- On a phone, the slim masthead of Folio's own narrow page: a
             smaller portrait half over a shorter band, the name beside it. --%>
        <div class="-mt-8 max-sm:mt-0 w-full flex flex-col items-center gap-3 [&_[data-role=preview-headline]]:font-serif max-sm:[&_[data-role=preview-identity]]:items-start max-sm:[&_[data-preview-avatar]]:-mt-5">
          {render_slot(@header)}
        </div>
        <PreviewWeek.calendar_area colors={@colors} highlight={@highlight}>
          <%!-- Shorter day cells on a phone leave room for the times. --%>
          <PreviewWeek.month_grid
            view={@view}
            colors={@colors}
            cell_class="rounded-token-full max-sm:aspect-auto max-sm:py-1.5"
          />
          <PreviewWeek.times
            view={@view}
            colors={@colors}
            layout={:chips}
            phone_limit={9}
            class="grid grid-cols-3 gap-1.5"
            highlight={@highlight}
            meeting_variant={:rule}
          />
        </PreviewWeek.calendar_area>
        <.book_button
          class="w-full py-2 rounded-token-lg font-semibold text-token-sm mt-1"
          style={"background: #{@primary}; color: #{@ink};"}
        />
      </div>
    </div>
    """
  end

  # White where it reads on the primary at 4.5:1, otherwise the darker of the
  # scheme's canvas and text, as ContrastTokens picks a filled control's ink.
  defp ink(colors) do
    primary = color(colors, :primary, "#b4532a")

    if Colour.contrast_ratio("#ffffff", primary) >= 4.5 do
      "#ffffff"
    else
      Enum.min_by(
        [color(colors, :background, "#faf7f2"), color(colors, :text, "#1f1b16")],
        &Colour.relative_luminance/1
      )
    end
  end
end
