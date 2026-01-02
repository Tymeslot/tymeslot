defmodule TymeslotWeb.Components.CoreComponents.Navigation do
  @moduledoc "Navigation components extracted from CoreComponents."
  use Phoenix.Component

  # ========== NAVIGATION ==========

  @doc """
  Renders a detail row for definition lists.
  """
  attr :label, :string, required: true
  attr :value, :string, required: true

  @spec detail_row(map()) :: Phoenix.LiveView.Rendered.t()
  def detail_row(assigns) do
    ~H"""
    <div class="flex justify-between">
      <dt style="color: rgba(255,255,255,0.7);">{@label}:</dt>
      <dd class="font-medium" style="color: white;">{@value}</dd>
    </div>
    """
  end

  @doc """
  Renders a styled back link.
  """
  attr :to, :string, required: true
  slot :inner_block, required: true

  @spec back_link(map()) :: Phoenix.LiveView.Rendered.t()
  def back_link(assigns) do
    ~H"""
    <.link
      navigate={@to}
      class="text-sm transition duration-200"
      style="color: rgba(255,255,255,0.7); text-decoration: underline;"
      onmouseover="this.style.color='rgba(255,255,255,0.9)'"
      onmouseout="this.style.color='rgba(255,255,255,0.7)'"
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end
end
