defmodule TymeslotWeb.Themes.Paper.OnboardingPreview do
  @moduledoc """
  Paper in the onboarding wizard, the shape of its first screen: one light
  card in two panes, the organiser's introduction on the left (the shared
  header, left-aligned) and a rule, then on the right the meeting types as
  a bordered list with the first one chosen in the palette's primary colour, the
  times the wizard explains its steps with, and one solid Book button in
  the palette's primary colour.
  """
  use Phoenix.Component

  import TymeslotWeb.OnboardingLive.PreviewParts,
    only: [
      book_button: 1,
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
      <div class="w-full h-full rounded-token-md bg-white border border-tymeslot-200 p-1.5 grid grid-cols-[2fr_3fr]">
        <div class="flex flex-col items-start gap-1 pr-1.5 border-r border-tymeslot-200">
          <span class="w-3 h-3 rounded-full bg-tymeslot-200" />
          <span class="h-1.5 w-full rounded-full bg-tymeslot-300" />
          <span class="h-1 w-2/3 rounded-full bg-tymeslot-200" />
        </div>
        <div class="pl-1.5 flex flex-col gap-1">
          <div class="flex flex-col rounded-token-sm border border-tymeslot-200 overflow-hidden">
            <span
              :for={row <- 0..2}
              class={["h-2.5", row > 0 && "border-t border-tymeslot-200"]}
              style={
                if(row == 0,
                  do: "border-left: 2px solid #{@primary}; background: #{@primary}14;",
                  else: nil
                )
              }
              data-preview-part="type"
            />
          </div>
          <span class="self-end h-2 w-1/3 rounded-token-sm" style={"background: #{@primary};"} />
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
    assigns =
      assign(assigns,
        primary: color(assigns.colors, :primary, "#07819e"),
        edge: edge(assigns.colors)
      )

    ~H"""
    <div
      class="rounded-token-xl p-4 border grid grid-cols-[minmax(0,5fr)_minmax(0,6fr)]"
      style={card_style(@colors, @highlight_card) <> "border-color: #{@edge};"}
      data-preview="paper"
    >
      <div
        class="min-w-0 pr-3 border-r flex flex-col items-start gap-2 text-left [overflow-wrap:anywhere] [&_p]:text-left"
        style={"border-color: #{@edge};"}
        data-preview-part="intro"
      >
        {render_slot(@header)}
      </div>
      <div class="min-w-0 pl-3 flex flex-col gap-2" data-preview-part="types">
        <div
          class="flex flex-col rounded-token-md border overflow-hidden"
          style={"border-color: #{@edge};"}
        >
          <span
            :for={row <- 0..1}
            class="flex flex-col gap-1 px-2 py-1.5"
            style={type_style(row, @primary, @edge)}
            data-preview-part="type"
          >
            <span class="h-1.5 w-3/4 rounded-full" style={"background: #{@edge};"} />
            <span class="h-1 w-1/2 rounded-full" style={"background: #{@edge};"} />
          </span>
        </div>
        <div
          class="flex flex-col gap-1.5"
          style={slots_style(@highlight_slots)}
          data-preview-part="times"
        >
          <.slot_row :for={slot <- @slots} colors={@colors} slot={slot} />
        </div>
        <.book_button
          class="w-full py-2 rounded-token-lg font-semibold text-white text-token-sm"
          style={"background: #{@primary};"}
        />
      </div>
    </div>
    """
  end

  # A meeting type's row: the first is the chosen one, a primary-colour edge on its
  # left and a faint tint of it, as Paper marks a chosen type.
  defp type_style(0, primary, _edge),
    do: "border-left: 2px solid #{primary}; background: #{primary}0f;"

  defp type_style(_row, _primary, edge), do: "border-top: 1px solid #{edge};"

  # The card's edge, the rule and the list's lines: the text colour at 12%,
  # as Paper's own lines are, so they follow a dark card instead of staying
  # a light grey.
  defp edge(colors), do: "#{color(colors, :text, "#111111")}1f"
end
