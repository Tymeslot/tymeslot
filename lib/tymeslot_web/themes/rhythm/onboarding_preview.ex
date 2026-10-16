defmodule TymeslotWeb.Themes.Rhythm.OnboardingPreview do
  @moduledoc """
  Rhythm in the onboarding wizard: compact and motion-driven, with tighter
  corners, a single week strip and a vertical list of time slots.
  """
  use Phoenix.Component

  import TymeslotWeb.OnboardingLive.PreviewParts,
    only: [
      book_button: 1,
      card_style: 2,
      color: 3,
      slot_row: 1,
      slots_style: 1,
      week_cell_style: 2
    ]

  alias TymeslotWeb.Helpers.LocaleFormat

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
  attr :slots, :list, required: true
  attr :locale, :string, required: true
  attr :highlight_card, :boolean, required: true
  attr :highlight_slots, :boolean, required: true
  slot :header, required: true

  @spec card(map()) :: Phoenix.LiveView.Rendered.t()
  def card(assigns) do
    ~H"""
    <div
      class="rounded-token-2xl p-5 flex flex-col items-center gap-3"
      style={card_style(@colors, @highlight_card)}
    >
      {render_slot(@header)}
      <div class="w-full flex flex-col gap-2">
        <%!-- Single week strip --%>
        <div class="flex justify-between gap-1">
          <span
            :for={day <- 0..6}
            class="grow h-6 rounded-token-md inline-flex items-center justify-center text-token-2xs font-semibold"
            style={week_cell_style(@colors, day == 2)}
          >
            {LocaleFormat.format_weekday_name(day + 1, @locale, :narrow)}
          </span>
        </div>

        <%!-- Vertical slot list --%>
        <div class="flex flex-col gap-1.5" style={slots_style(@highlight_slots)}>
          <.slot_row :for={slot <- @slots} colors={@colors} slot={slot} />
        </div>
      </div>
      <.book_button
        class="w-full py-2 rounded-token-lg font-semibold text-white text-token-sm mt-1"
        style={"background: #{color(@colors, :primary, "#14b8a6")};"}
      />
    </div>
    """
  end
end
