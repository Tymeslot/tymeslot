defmodule Tymeslot.ThemeCustomizations.PaletteDerivation do
  @moduledoc """
  Derives a full 8-token colour palette from a single seed colour.

  Returns a map shaped identically to the static presets in
  `Tymeslot.ThemeCustomizations.ThemeCustomizationSchema.color_scheme_definitions/0`,
  so it can be substituted transparently in CSS generation when the user has
  picked the "custom" scheme.

  The derivation uses HSL transforms tuned to mirror the look-and-feel of the
  hand-tuned presets: primary/hover/secondary/accent share the seed's hue
  family with luminosity and saturation shifts, while background and text
  tokens collapse to low-chroma derivatives so legibility remains stable
  regardless of seed choice.

  The colour maths itself lives in `Tymeslot.Utils.Colour`; this module owns
  only the transforms that define the booking-page look.
  """

  alias Tymeslot.Utils.Colour

  @typedoc "An 8-token palette in the shape used by the rest of the theme system."
  @type palette :: %{
          name: String.t(),
          colors: %{
            primary: String.t(),
            primary_hover: String.t(),
            secondary: String.t(),
            accent: String.t(),
            background: String.t(),
            surface: String.t(),
            text: String.t(),
            text_secondary: String.t()
          }
        }

  @doc """
  Derives a palette from a hex seed colour.

  Accepts 6-character hex strings (with leading `#`). Invalid input returns
  `nil` so callers can fall back to a default scheme.
  """
  @spec derive_palette(String.t() | nil) :: palette() | nil
  def derive_palette(nil), do: nil

  def derive_palette(seed_hex) when is_binary(seed_hex) do
    case Colour.hex_to_hsl(seed_hex) do
      nil ->
        nil

      {h, s, l} ->
        %{
          name: "Custom",
          colors: %{
            primary: Colour.normalise_hex(seed_hex),
            primary_hover: Colour.hsl_to_hex({h, s, Colour.clamp(l - 0.08, 0.0, 1.0)}),
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
        }
    end
  end
end
