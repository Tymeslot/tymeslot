defmodule TymeslotWeb.Components.CoreComponents.Icons do
  @moduledoc """
  The one icon component, `<.icon>`, and the renderer behind it.

  Every icon in the app is drawn here, from one of two compile-time sets:
  `hero-*` names from the vendored Heroicons, and the few marks Heroicons does
  not ship (brand logos) from `CustomIcons`. An app layered on top of Core
  keeps its own extra icons in its own set and renders them with `svg/1`, so
  they paint with exactly the same markup.
  """
  use Phoenix.Component

  alias TymeslotWeb.Components.CoreComponents.CustomIcons
  alias TymeslotWeb.Components.CoreComponents.Heroicons
  alias TymeslotWeb.Components.CoreComponents.IconSource

  @doc """
  Renders an icon as inline SVG.

  `hero-{name}` is a Heroicon in its outline style; the `-solid`, `-mini` and
  `-micro` suffixes select the others. Any other name is one of Core's custom
  icons in `priv/icons` (e.g. `brand-slack`).

  Size and colour come from classes (`w-5 h-5 text-turquoise-500`): the icon
  inherits `currentColor`, and with no size class it falls back to its
  intrinsic size (24/20/16px). A stroke-weight class (`stroke-2`) thickens an
  outline icon. An unknown name renders an empty span rather than crashing.

  ## Examples

      <.icon name="hero-x-mark-solid" />
      <.icon name="hero-arrow-path" class="ml-1 w-3 h-3 animate-spin" />
      <.icon name="brand-slack" class="w-6 h-6" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: nil
  attr :style, :string, default: nil
  attr :rest, :global

  @spec icon(map()) :: Phoenix.LiveView.Rendered.t()
  def icon(assigns) do
    case fetch(assigns.name) do
      {:ok, icon} -> svg(assign(assigns, :icon, icon))
      :error -> unknown(assigns)
    end
  end

  @doc "Whether `name` is an icon `<.icon>` can draw."
  @spec known?(String.t()) :: boolean()
  def known?(name), do: fetch(name) != :error

  @doc """
  Draws an already fetched icon (`assigns.icon`, from an `IconSource` set) as
  inline SVG, with `class`, `style` and any global attributes.

  This is the renderer `icon/1` uses; an app with an icon set of its own calls
  it so its icons get identical markup.
  """
  @spec svg(map()) :: Phoenix.LiveView.Rendered.t()
  def svg(assigns) do
    assigns = assign_new(assigns, :rest, fn -> %{} end)

    # The intrinsic width/height attributes give the default size and lose to
    # any `w-*` / `h-*` class (CSS beats SVG presentation attributes). The body
    # is trusted path markup read from priv at compile time, so `raw/1` is safe.
    ~H"""
    <svg
      class={@class}
      style={@style}
      width={@icon.size}
      height={@icon.size}
      {@icon.attrs}
      aria-hidden="true"
      xmlns="http://www.w3.org/2000/svg"
      {@rest}
    >{Phoenix.HTML.raw(@icon.body)}</svg>
    """
  end

  @doc "The empty placeholder drawn for a name no icon set knows."
  @spec unknown(map()) :: Phoenix.LiveView.Rendered.t()
  def unknown(assigns) do
    ~H"""
    <span class={@class} style={@style} />
    """
  end

  @spec fetch(String.t()) :: {:ok, IconSource.icon()} | :error
  defp fetch("hero-" <> _rest = name), do: Heroicons.fetch(name)
  defp fetch(name) when is_binary(name), do: CustomIcons.fetch(name)
  defp fetch(_name), do: :error
end
