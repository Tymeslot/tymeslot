defmodule Tymeslot.ThemeCustomizations.ContrastTokens do
  @moduledoc """
  Derives the accessible ink/surface pairs used wherever booking-page text sits
  directly on a palette colour: filled controls, where the palette colour is
  the surface and something has to be legible on top of it.

  White was hard-coded there once, and it fails WCAG AA against six of the
  eight shipped primaries (2.43:1 for the default turquoise) and against every
  accent, with a custom seed free to be worse still.

  Two tokens per family fix that without discarding the organiser's colour:

    * `on_*` picks the ink: white, or the palette's own dark colour, whichever
      already reads better on the surface. The dark colour is the darker of
      the palette's `background` and `text`: the page ground on a dark scheme,
      the body text on a light one, so the rule needs no notion of mode.
      Taking it from the palette rather than pure black keeps a dark ink in
      the same family as the rest of the page.
    * `*_solid` nudges the surface's lightness towards the ink until
      normal-size text clears 4.5:1. In practice this moves nothing at all for
      half the palettes and is a barely perceptible shift for the rest,
      because the ink was chosen to start as close as possible.

  `--theme-primary` itself is deliberately left untouched here: it is also
  used for borders, focus rings and text on the card, where nudging it
  towards a filled control's ink could lower its contrast against the card
  instead. Only the filled surfaces read the `*_solid` variants. Whether the
  primary reads as text on the card is the separate rule `fit_text/3`, which
  whoever sets the primary applies: the light seed derivation and the accent
  option do; the dark schemes pair bright primaries with a dark card by
  design.
  """

  alias Tymeslot.Utils.Colour

  @min_contrast 4.5
  @light_ink "#ffffff"
  @dark_end "#000000"

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

  @doc """
  `colour`, moved just far enough to read as text on `ground`.

  Its HSL lightness walks away from the ground in small steps until the pair
  clears `min_ratio` (4.5:1 by default, WCAG AA for normal-size text; pass
  3.0 for large text and non-text marks). Hue and saturation are kept, so the
  result is still the organiser's colour. The direction depends on the ground
  alone: towards white where white reads better on it than black does,
  towards black otherwise, so the walk heads for the end that can reach the
  ratio. A colour that already clears it comes back unchanged, as lower-case
  `#rrggbb`.

  Both colours are hex (`#RGB` or `#RRGGBB`).
  """
  @spec fit_text(String.t(), String.t(), number()) :: String.t()
  def fit_text(colour, ground, min_ratio \\ @min_contrast)
      when is_binary(colour) and is_binary(ground) do
    hex = Colour.normalise_hex(colour)

    cond do
      Colour.contrast_ratio(hex, ground) >= min_ratio ->
        hex

      lighter_reads_better?(ground) ->
        Colour.hsl_to_hex(
          Colour.lighten_until_contrast(Colour.hex_to_hsl(hex), ground, min_ratio)
        )

      true ->
        Colour.hsl_to_hex(Colour.darken_until_contrast(Colour.hex_to_hsl(hex), ground, min_ratio))
    end
  end

  defp lighter_reads_better?(ground),
    do: Colour.contrast_ratio(@light_ink, ground) >= Colour.contrast_ratio(@dark_end, ground)

  defp build(primary, colors) do
    hover = hex(colors[:primary_hover]) || primary
    accent = hex(colors[:accent]) || primary
    dark_ink = dark_ink(colors)

    primary_ink = ink(dark_ink, [primary, hover])
    accent_ink = ink(dark_ink, [accent])

    %{
      on_primary: primary_ink,
      primary_solid: fit(primary, primary_ink),
      primary_solid_hover: fit(hover, primary_ink),
      on_accent: accent_ink,
      accent_solid: fit(accent, accent_ink)
    }
  end

  # The palette's own dark colour: the darker of its background and its text,
  # which is the background on a dark scheme and the text on a light one.
  # `nil` when the palette has neither as a hex colour.
  defp dark_ink(colors) do
    [colors[:background], colors[:text]]
    |> Enum.map(&hex/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(&Colour.relative_luminance/1, fn -> nil end)
  end

  # White unless the palette's dark colour reads better across every surface
  # the ink has to cover; a gradient's two stops both have to clear the bar.
  defp ink(nil, _surfaces), do: @light_ink

  defp ink(dark_ink, surfaces) do
    if worst_contrast(dark_ink, surfaces) > worst_contrast(@light_ink, surfaces) do
      dark_ink
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
