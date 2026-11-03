defmodule TymeslotWeb.Themes.Rhythm.OnboardingPreview do
  @moduledoc """
  Rhythm in the onboarding wizard: compact and motion-driven, with tighter
  corners, a strip of the host's coming week and the chosen day as a
  vertical list, busy blocks between its times.
  """
  use Phoenix.Component

  import TymeslotWeb.OnboardingLive.PreviewParts,
    only: [book_button: 1, card_style: 1, color: 3]

  alias TymeslotWeb.OnboardingLive.PreviewWeek

  @doc "Draws the `:thumbnail` or `:card` variant; see `Behaviour.onboarding_preview/1`."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(%{variant: :thumbnail} = assigns), do: thumbnail(assigns)
  def render(%{variant: :card} = assigns), do: card(assigns)

  attr :primary, :string, required: true

  @spec thumbnail(map()) :: Phoenix.LiveView.Rendered.t()
  def thumbnail(assigns) do
    ~H"""
    <div class="aspect-[4/3] w-full rounded-token-lg bg-tymeslot-900 p-2 flex flex-col gap-1.5 overflow-hidden">
      <div class="h-1.5 w-2/3 rounded-full bg-white/30" />
      <div :for={_row <- 1..3} class="h-2.5 rounded-token-sm bg-white/10 flex items-center px-1">
        <span class="h-1 w-1/3 rounded-full" style={"background: #{@primary};"} />
      </div>
    </div>
    """
  end

  attr :colors, :map, required: true
  attr :view, :map, required: true, doc: "the week, from `PreviewWeek.view/3`"
  attr :reveal, :boolean, default: false
  attr :highlight, :list, default: []
  slot :header, required: true

  @spec card(map()) :: Phoenix.LiveView.Rendered.t()
  def card(assigns) do
    ~H"""
    <div class="rounded-token-2xl p-5 flex flex-col items-center gap-3" style={card_style(@colors)}>
      {render_slot(@header)}
      <PreviewWeek.calendar_area colors={@colors} highlight={@highlight} class="flex flex-col gap-2">
        <%!-- Single week strip --%>
        <PreviewWeek.day_strip view={@view} colors={@colors} />

        <%!-- The chosen day, its busy blocks between the times --%>
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
end
