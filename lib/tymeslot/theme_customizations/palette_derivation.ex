defmodule Tymeslot.ThemeCustomizations.PaletteDerivation do
  @moduledoc """
  Derives a full colour palette from a single seed colour, for a dark or a
  light page.

  Returns a map in the shape of the colour-scheme presets in
  `Tymeslot.ThemeCustomizations.Presets.ColourSchemes` (`name`, `mode`,
  `colors`, and for a light palette `dark_colors`), so a custom seed stands in
  for a preset wherever a scheme is resolved.

  The derivation uses HSL transforms tuned to mirror the look of the
  hand-tuned presets: primary, hover, secondary and accent share the seed's
  hue family with lightness and saturation shifts, while background and text
  collapse to low-chroma derivatives so legibility stays stable whatever the
  seed. A dark palette puts light text on a near-black ground, a light one
  dark text on a near-white ground. A light palette's `dark_colors` is the
  dark palette of the same seed, so a theme that follows the visitor's OS
  shows, in dark mode, the palette a dark theme derives from that seed. A
  light palette's primary is fitted to read as text on its surface, and its
  secondary and accent to show on its ground (`ContrastTokens.fit_text/3`), so
  a bright seed stays legible on white; the dark derivation takes the seed as
  it is.

  The colour maths itself lives in `Tymeslot.Utils.Colour`; this module owns
  only the transforms that define the booking-page look.
  """

  alias Tymeslot.ThemeCustomizations.ContrastTokens
  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.Utils.Colour

  # WCAG's bar for large text and non-text marks: what a light palette's
  # secondary and accent must reach on its ground.
  @mark_contrast 3.0

  @typedoc "Which kind of page a palette is for."
  @type mode :: :light | :dark

  @typedoc "A derived palette, in the shape of a colour-scheme preset."
  @type palette :: Presets.color_scheme_preset()

  @doc """
  Derives a palette from a hex seed colour: for a dark page unless `mode` is
  `:light`.

  Accepts `#RGB` or `#RRGGBB`. Invalid input returns `nil` so callers can fall
  back to a default scheme.
  """
  @spec derive_palette(String.t() | nil, mode()) :: palette() | nil
  def derive_palette(seed_hex, mode \\ :dark)

  def derive_palette(nil, _mode), do: nil

  def derive_palette(seed_hex, mode) when is_binary(seed_hex) and mode in [:light, :dark] do
    case Colour.hex_to_hsl(seed_hex) do
      nil -> nil
      hsl -> palette(mode, Colour.normalise_hex(seed_hex), hsl)
    end
  end

  @doc """
  The hover shade the derivation pairs with a primary colour: the same hue
  and saturation, eight points darker.

  Shared by custom palettes and the per-request primary-colour override, so a
  page's hover state always follows its primary. Returns `nil` for an invalid
  colour.
  """
  @spec hover_for(String.t()) :: String.t() | nil
  def hover_for(hex) when is_binary(hex) do
    case Colour.hex_to_hsl(hex) do
      nil -> nil
      {h, s, l} -> Colour.hsl_to_hex({h, s, Colour.clamp(l - 0.08, 0.0, 1.0)})
    end
  end

  defp palette(:dark, seed, hsl),
    do: %{name: "Custom", mode: :dark, colors: dark_colors(seed, hsl)}

  defp palette(:light, seed, hsl) do
    %{
      name: "Custom",
      mode: :light,
      colors: light_colors(seed, hsl),
      dark_colors: dark_colors(seed, hsl)
    }
  end

  # Light text on a near-black ground; the transforms Quill and Rhythm have
  # always used.
  defp dark_colors(seed, {h, s, l}) do
    %{
      primary: seed,
      primary_hover: hover_for(seed),
      secondary:
        Colour.hsl_to_hex({
          Colour.wrap_hue(h - 15.0),
          Colour.clamp(s * 0.85, 0.0, 1.0),
          Colour.clamp(l + 0.08, 0.0, 0.72)
        }),
      accent:
        Colour.hsl_to_hex({
          Colour.wrap_hue(h + 30.0),
          s,
          Colour.clamp(l + 0.15, 0.0, 0.78)
        }),
      background: Colour.hsl_to_hex({h, 0.40, 0.08}),
      surface: Colour.hsl_to_rgba({h, 0.30, 0.18}, 0.5),
      text: Colour.hsl_to_hex({h, 0.15, 0.92}),
      text_secondary: Colour.hsl_to_hex({h, 0.15, 0.72})
    }
  end

  # Dark text on a near-white ground. The primary is the seed, darkened only
  # as far as it must be to read as text on the surface, and its hover
  # follows it. Secondary and accent keep the dark palette's hue shifts and
  # sit in the middle lightness band, darkened where a bright hue needs it to
  # show at 3:1 on the ground.
  defp light_colors(seed, {h, s, l}) do
    background = Colour.hsl_to_hex({h, 0.25, 0.96})
    surface = Colour.hsl_to_hex({h, 0.30, 0.995})
    primary = ContrastTokens.fit_text(seed, surface)

    secondary =
      Colour.hsl_to_hex({
        Colour.wrap_hue(h - 15.0),
        Colour.clamp(s * 0.85, 0.0, 1.0),
        Colour.clamp(l, 0.25, 0.5)
      })

    accent = Colour.hsl_to_hex({Colour.wrap_hue(h + 30.0), s, Colour.clamp(l, 0.25, 0.5)})

    %{
      primary: primary,
      primary_hover: hover_for(primary),
      secondary: ContrastTokens.fit_text(secondary, background, @mark_contrast),
      accent: ContrastTokens.fit_text(accent, background, @mark_contrast),
      background: background,
      surface: surface,
      text: Colour.hsl_to_hex({h, 0.25, 0.12}),
      text_secondary: Colour.hsl_to_hex({h, 0.15, 0.38})
    }
  end
end
