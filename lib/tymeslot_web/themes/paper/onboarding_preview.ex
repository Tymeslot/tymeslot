defmodule TymeslotWeb.Themes.Paper.OnboardingPreview do
  @moduledoc """
  Paper in the onboarding wizard: a light card on a light page, the
  meeting's details beside a small month calendar and a column of times,
  and one solid Book button in the accent colour.
  """
  use Phoenix.Component

  import TymeslotWeb.OnboardingLive.PreviewParts,
    only: [
      book_button: 1,
      calendar_cell_style: 2,
      card_style: 2,
      color: 3,
      slot_row: 1,
      slots_style: 1
    ]

  @doc "Draws the `:thumbnail` or `:card` variant; see `Behaviour.onboarding_preview/1`."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(%{variant: :thumbnail} = assigns), do: thumbnail(assigns)
  def render(%{variant: :card} = assigns), do: card(assigns)

  attr :primary, :string, required: true

  @spec thumbnail(map()) :: Phoenix.LiveView.Rendered.t()
  def thumbnail(assigns) do
    ~H"""
    <div
      class="aspect-[4/3] w-full rounded-token-lg bg-tymeslot-100 p-2 flex items-center justify-center overflow-hidden"
      data-preview="paper"
    >
      <div class="w-full h-full rounded-token-md bg-white border border-tymeslot-200 p-1.5 grid grid-cols-3 gap-1">
        <div class="flex flex-col gap-1">
          <span class="w-3 h-3 rounded-full bg-tymeslot-200" />
          <span class="h-1 w-full rounded-full bg-tymeslot-300" />
          <span class="h-1 w-2/3 rounded-full bg-tymeslot-200" />
        </div>
        <div class="grid grid-cols-4 gap-0.5 content-start">
          <span
            :for={cell <- 0..11}
            class="aspect-square rounded-token-sm"
            style={
              if(cell in [5, 9],
                do: "background: #{@primary};",
                else: "background: #{@primary}1f;"
              )
            }
          />
        </div>
        <div class="flex flex-col gap-0.5">
          <span
            :for={_n <- 1..3}
            class="h-2 rounded-token-sm border"
            style={"border-color: #{@primary};"}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :colors, :map, required: true
  attr :slots, :list, required: true
  attr :highlight_card, :boolean, default: false
  attr :highlight_slots, :boolean, default: false
  slot :header, required: true

  @spec card(map()) :: Phoenix.LiveView.Rendered.t()
  def card(assigns) do
    ~H"""
    <div
      class="rounded-token-xl p-5 flex flex-col items-center gap-3 border border-tymeslot-200"
      style={card_style(@colors, @highlight_card)}
      data-preview="paper"
    >
      {render_slot(@header)}
      <div class="w-full grid grid-cols-5 gap-3">
        <div
          class="col-span-3 grid grid-cols-7 gap-1 content-start"
          style={slots_style(@highlight_slots)}
          data-preview-part="calendar"
        >
          <span
            :for={day <- 0..20}
            class="aspect-square rounded-token-md"
            style={calendar_cell_style(@colors, day)}
          />
        </div>
        <div
          class="col-span-2 flex flex-col gap-1.5"
          style={slots_style(@highlight_slots)}
          data-preview-part="times"
        >
          <.slot_row :for={slot <- @slots} colors={@colors} slot={slot} />
        </div>
      </div>
      <.book_button
        class="w-full py-2 rounded-token-lg font-semibold text-white text-token-sm mt-1"
        style={"background: #{color(@colors, :primary, "#07819e")};"}
      />
    </div>
    """
  end
end
