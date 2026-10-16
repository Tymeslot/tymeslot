defmodule TymeslotWeb.Themes.Quill.OnboardingPreview do
  @moduledoc """
  Quill in the onboarding wizard: the signature numbered step band over a
  month calendar grid and a multi-column slot grid, generous corners, and a
  primary-to-accent gradient on the Book button.
  """
  use Phoenix.Component

  import TymeslotWeb.OnboardingLive.PreviewParts,
    only: [
      book_button: 1,
      calendar_cell_style: 2,
      card_style: 2,
      color: 3,
      divider_style: 1,
      slot_chip: 1,
      slots_style: 1,
      step_dot_style: 2
    ]

  @doc "Draws the `:thumbnail` or `:card` variant; see `Behaviour.onboarding_preview/1`."
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(%{variant: :thumbnail} = assigns), do: thumbnail(assigns)
  def render(%{variant: :card} = assigns), do: card(assigns)

  attr :primary, :string, required: true

  @spec thumbnail(map()) :: Phoenix.LiveView.Rendered.t()
  def thumbnail(assigns) do
    ~H"""
    <div class="aspect-[4/3] w-full rounded-token-lg bg-tymeslot-900 p-2 flex flex-col gap-1.5 overflow-hidden">
      <div class="flex items-center justify-center gap-1">
        <span
          :for={n <- 1..4}
          class="w-2 h-2 rounded-full"
          style={
            if(n == 1, do: "background: #{@primary};", else: "background: rgba(255,255,255,0.25);")
          }
        />
      </div>
      <div class="grid grid-cols-5 gap-0.5">
        <span
          :for={cell <- 0..9}
          class="aspect-square rounded-token-sm"
          style={
            if(cell in [2, 6],
              do: "background: #{@primary};",
              else: "background: rgba(255,255,255,0.12);"
            )
          }
        />
      </div>
    </div>
    """
  end

  attr :colors, :map, required: true
  attr :slots, :list, required: true
  attr :highlight_card, :boolean, required: true
  attr :highlight_slots, :boolean, required: true
  slot :header, required: true

  @spec card(map()) :: Phoenix.LiveView.Rendered.t()
  def card(assigns) do
    ~H"""
    <div
      class="rounded-token-3xl p-5 flex flex-col items-center gap-3"
      style={card_style(@colors, @highlight_card)}
    >
      {render_slot(@header)}
      <div class="w-full flex flex-col gap-3">
        <%!-- Signature numbered step band --%>
        <div class="flex items-center justify-center gap-1.5">
          <span :for={n <- 1..4} class="contents">
            <span
              class="w-5 h-5 rounded-full text-token-2xs font-bold inline-flex items-center justify-center"
              style={step_dot_style(@colors, n == 1)}
            >
              {n}
            </span>
            <span :if={n < 4} class="w-3 h-px" style={divider_style(@colors)} />
          </span>
        </div>

        <%!-- Mini month calendar (7 columns) --%>
        <div class="grid grid-cols-7 gap-1" style={slots_style(@highlight_slots)}>
          <span
            :for={day <- 0..20}
            class="aspect-square rounded-token-sm"
            style={calendar_cell_style(@colors, day)}
          />
        </div>

        <%!-- Multi-column slot grid --%>
        <div class="grid grid-cols-2 gap-1.5" style={slots_style(@highlight_slots)}>
          <.slot_chip :for={slot <- @slots} colors={@colors} slot={slot} />
        </div>
      </div>
      <.book_button
        class="w-full py-2 rounded-token-xl font-semibold text-white text-token-sm mt-1"
        style={"background: linear-gradient(135deg, #{color(@colors, :primary, "#14b8a6")}, #{color(@colors, :accent, "#f59e0b")});"}
      />
    </div>
    """
  end
end
