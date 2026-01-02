defmodule TymeslotWeb.Components.CoreComponents.Icons do
  @moduledoc "Icon components extracted from CoreComponents."
  use Phoenix.Component

  # ========== ICONS ==========

  @doc """
  Renders a heroicon.

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `heroicons` library.

  ## Examples

      <.icon name="hero-x-mark-solid" />
      <.icon name="hero-arrow-path" class="ml-1 w-3 h-3 animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: nil
  attr :style, :string, default: nil

  @spec icon(map()) :: Phoenix.LiveView.Rendered.t()
  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} style={@style} />
    """
  end

  @spec icon(map()) :: Phoenix.LiveView.Rendered.t()
  def icon(%{name: name} = assigns) when is_binary(name) do
    ~H"""
    <span class={@class}>{@name}</span>
    """
  end
end
