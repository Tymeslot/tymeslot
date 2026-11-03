defmodule TymeslotWeb.Themes.Rhythm.OnboardingPreview do
  @moduledoc """
  Rhythm in the onboarding wizard: compact and motion-driven. Its card is
  the generic one (a strip of the host's coming week and the chosen day as
  a vertical list, busy blocks between its times) with tighter corners.
  """
  use Phoenix.Component

  alias TymeslotWeb.OnboardingLive.PreviewParts

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

  @doc "The generic card, with Rhythm's tighter corners."
  @spec card(map()) :: Phoenix.LiveView.Rendered.t()
  def card(assigns), do: PreviewParts.generic(assign(assigns, :radius, "rounded-token-xl"))
end
