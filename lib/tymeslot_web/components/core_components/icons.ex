defmodule TymeslotWeb.Components.CoreComponents.Icons do
  @moduledoc "Icon components extracted from CoreComponents."
  use Phoenix.Component

  alias TymeslotWeb.Components.CoreComponents.Heroicons

  # ========== ICONS ==========

  @doc """
  Renders a heroicon as inline SVG.

  Heroicons come in four styles – outline (default), solid, mini, and micro.
  The outline style is used by default; the `-solid`, `-mini`, and `-micro`
  suffixes select the others.

  You can customise the size and colour of the icons by setting width, height
  (e.g. `w-5 h-5`) and text-colour classes — the icon inherits `currentColor`.
  When no size class is given it falls back to the heroicon's intrinsic size
  (24/20/16px), matching the previous mask-image behaviour.

  Icons are inlined from the `heroicons` library at compile time (see
  `TymeslotWeb.Components.CoreComponents.Heroicons`).

  ## Examples

      <.icon name="hero-x-mark-solid" />
      <.icon name="hero-arrow-path" class="ml-1 w-3 h-3 animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: nil
  attr :style, :string, default: nil

  @spec icon(map()) :: Phoenix.LiveView.Rendered.t()
  def icon(%{name: "hero-" <> _rest} = assigns) do
    case Heroicons.fetch(assigns.name) do
      {:ok, icon} -> render_heroicon(assign(assigns, :icon, icon))
      :error -> render_unknown_heroicon(assigns)
    end
  end

  def icon(%{name: name} = assigns) when is_binary(name) do
    ~H"""
    <span class={@class}>{@name}</span>
    """
  end

  # Intrinsic width/height attributes provide the default size and are overridden
  # by any `w-*` / `h-*` class (CSS beats SVG presentation attributes). `@body` is
  # the trusted path markup from the heroicons dep, so `raw/1` is safe here.
  defp render_heroicon(%{icon: %{outline?: true}} = assigns) do
    ~H"""
    <svg
      class={@class}
      style={@style}
      width={@icon.size}
      height={@icon.size}
      viewBox={@icon.view_box}
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      aria-hidden="true"
      xmlns="http://www.w3.org/2000/svg"
    >{Phoenix.HTML.raw(@icon.body)}</svg>
    """
  end

  defp render_heroicon(assigns) do
    ~H"""
    <svg
      class={@class}
      style={@style}
      width={@icon.size}
      height={@icon.size}
      viewBox={@icon.view_box}
      fill="currentColor"
      aria-hidden="true"
      xmlns="http://www.w3.org/2000/svg"
    >{Phoenix.HTML.raw(@icon.body)}</svg>
    """
  end

  # Unknown name: degrade gracefully (matches the old mask span, which simply
  # painted nothing when no rule matched) rather than crashing on a stray name.
  defp render_unknown_heroicon(assigns) do
    ~H"""
    <span class={@class} style={@style} />
    """
  end
end
