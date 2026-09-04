defmodule Tymeslot.ThemeCustomizations.ContrastTokens do
  @moduledoc """
  Derives the accessible ink/surface pairs used wherever booking-page text sits
  directly on a palette colour.

  The palettes are chosen for their look on the dark glass background, where
  they are only ever used as borders, focus rings, or bright text. Filled
  controls invert that relationship: the palette colour becomes the surface and
  something has to be legible on top of it. White was hard-coded there, and it
  fails WCAG AA against six of the eight shipped primaries (2.43:1 for the
  default turquoise) and against every accent, with a custom seed free to be
  worse still.

  Two tokens per family fix that without discarding the organiser's colour:

    * `on_*` picks the ink, white or the palette's own background colour,
      whichever already reads better on the surface. Using the palette
      background rather than pure black keeps a dark ink in the same family as
      the rest of the page.
    * `*_solid` nudges the surface's lightness towards the ink until normal-size
      text clears 4.5:1. In practice this moves nothing at all for half the
      palettes and is a barely perceptible shift for the rest, because the ink
      was chosen to start as close as possible.

  `--theme-primary` itself is deliberately left untouched: it is also used for
  borders, focus rings, and bright text on the dark card, where darkening it
  would *reduce* contrast. Only the filled surfaces read the `*_solid` variants.
  """

  alias Tymeslot.Utils.Colour

  @min_contrast 4.5
  @light_ink "#ffffff"

  @typedoc "Accessible ink and surface tokens derived from a palette."
  @type tokens :: %{
          on_primary: String.t(),
          primary_solid: String.t(),
          primary_solid_hover: String.t(),
          on_accent: String.t(),
          accent_solid: String.t()
        }

  @doc """
  Derives the contrast tokens for a palette's `colors` map.

  Returns `nil` when the palette carries no usable `:primary`, so callers can
  fall through to the theme's own static defaults rather than emitting a
  half-built set.
  """
  @spec derive(map()) :: tokens() | nil
  def derive(colors) when is_map(colors) do
    case hex(colors[:primary]) do
      nil -> nil
      primary -> build(primary, colors)
    end
  end

  def derive(_other), do: nil

  defp build(primary, colors) do
    hover = hex(colors[:primary_hover]) || primary
    accent = hex(colors[:accent]) || primary
    background = hex(colors[:background])

    primary_ink = ink(background, [primary, hover])
    accent_ink = ink(background, [accent])

    %{
      on_primary: primary_ink,
      primary_solid: fit(primary, primary_ink),
      primary_solid_hover: fit(hover, primary_ink),
      on_accent: accent_ink,
      accent_solid: fit(accent, accent_ink)
    }
  end

  # White unless the palette's own background reads better across every surface
  # the ink has to cover — a gradient's two stops both have to clear the bar.
  defp ink(nil, _surfaces), do: @light_ink

  defp ink(background, surfaces) do
    if worst_contrast(background, surfaces) > worst_contrast(@light_ink, surfaces) do
      background
    else
      @light_ink
    end
  end

  defp worst_contrast(candidate, surfaces) do
    surfaces
    |> Enum.map(&Colour.contrast_ratio(candidate, &1))
    |> Enum.min()
  end

  # Walks the surface away from the ink until normal-size text clears AA.
  defp fit(surface, ink) do
    hsl = Colour.hex_to_hsl(surface)

    fitted =
      if Colour.relative_luminance(ink) > Colour.relative_luminance(surface) do
        Colour.darken_until_contrast(hsl, ink, @min_contrast)
      else
        Colour.lighten_until_contrast(hsl, ink, @min_contrast)
      end

    Colour.hsl_to_hex(fitted)
  end

  defp hex(value) when is_binary(value) do
    if Colour.parse_hex(value), do: Colour.normalise_hex(value), else: nil
  end

  defp hex(_other), do: nil
end
