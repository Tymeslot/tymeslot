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
  """

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
    case hex_to_hsl(seed_hex) do
      nil ->
        nil

      {h, s, l} ->
        %{
          name: "Custom",
          colors: %{
            primary: normalise_hex(seed_hex),
            primary_hover: hsl_to_hex({h, s, clamp(l - 0.08, 0.0, 1.0)}),
            secondary:
              hsl_to_hex({
                wrap_hue(h - 15.0),
                clamp(s * 0.85, 0.0, 1.0),
                clamp(l + 0.08, 0.0, 0.72)
              }),
            accent:
              hsl_to_hex({
                wrap_hue(h + 30.0),
                s,
                clamp(l + 0.15, 0.0, 0.78)
              }),
            background: hsl_to_hex({h, 0.40, 0.08}),
            surface: hsl_to_rgba({h, 0.30, 0.18}, 0.5),
            text: hsl_to_hex({h, 0.15, 0.92}),
            text_secondary: hsl_to_hex({h, 0.15, 0.72})
          }
        }
    end
  end

  # --- Colour math --------------------------------------------------------

  @spec hex_to_hsl(String.t()) :: {float(), float(), float()} | nil
  defp hex_to_hsl(hex) do
    case parse_hex(hex) do
      nil -> nil
      {r, g, b} -> rgb_to_hsl(r / 255, g / 255, b / 255)
    end
  end

  @spec parse_hex(String.t()) :: {integer(), integer(), integer()} | nil
  defp parse_hex(<<"#", r1, r2, g1, g2, b1, b2>>) do
    with {r, ""} <- Integer.parse(<<r1, r2>>, 16),
         {g, ""} <- Integer.parse(<<g1, g2>>, 16),
         {b, ""} <- Integer.parse(<<b1, b2>>, 16) do
      {r, g, b}
    else
      _other -> nil
    end
  end

  defp parse_hex(<<"#", r, g, b>>) do
    parse_hex(<<"#", r, r, g, g, b, b>>)
  end

  defp parse_hex(_invalid), do: nil

  defp rgb_to_hsl(r, g, b) do
    max_c = max(max(r, g), b)
    min_c = min(min(r, g), b)
    l = (max_c + min_c) / 2
    delta = max_c - min_c

    {h, s} =
      if delta == 0 do
        {0.0, 0.0}
      else
        s =
          if l > 0.5,
            do: delta / (2 - max_c - min_c),
            else: delta / (max_c + min_c)

        h_raw =
          cond do
            max_c == r -> rem_float((g - b) / delta, 6.0)
            max_c == g -> (b - r) / delta + 2
            true -> (r - g) / delta + 4
          end

        h = h_raw * 60
        {wrap_hue(h), s}
      end

    {h, s, l}
  end

  defp hsl_to_rgb({h, s, l}) do
    c = (1 - abs(2 * l - 1)) * s
    h_prime = h / 60
    x = c * (1 - abs(rem_float(h_prime, 2.0) - 1))
    m = l - c / 2

    {r1, g1, b1} =
      cond do
        h_prime < 1 -> {c, x, 0.0}
        h_prime < 2 -> {x, c, 0.0}
        h_prime < 3 -> {0.0, c, x}
        h_prime < 4 -> {0.0, x, c}
        h_prime < 5 -> {x, 0.0, c}
        true -> {c, 0.0, x}
      end

    {to_byte(r1 + m), to_byte(g1 + m), to_byte(b1 + m)}
  end

  defp hsl_to_hex({_h, _s, _l} = hsl) do
    {r, g, b} = hsl_to_rgb(hsl)
    "#" <> byte_to_hex(r) <> byte_to_hex(g) <> byte_to_hex(b)
  end

  defp hsl_to_rgba({_h, _s, _l} = hsl, alpha) do
    {r, g, b} = hsl_to_rgb(hsl)
    "rgba(#{r}, #{g}, #{b}, #{alpha})"
  end

  defp normalise_hex(hex) do
    case hex |> String.trim() |> String.downcase() do
      <<"#", r, g, b>> -> <<"#", r, r, g, g, b, b>>
      other -> other
    end
  end

  defp byte_to_hex(byte) do
    byte
    |> Integer.to_string(16)
    |> String.pad_leading(2, "0")
    |> String.downcase()
  end

  defp to_byte(channel) do
    channel
    |> Kernel.*(255)
    |> Float.round()
    |> trunc()
    |> clamp(0, 255)
  end

  defp clamp(n, lo, _hi) when n < lo, do: lo
  defp clamp(n, _lo, hi) when n > hi, do: hi
  defp clamp(n, _lo, _hi), do: n

  defp wrap_hue(h) when h < 0, do: wrap_hue(h + 360)
  defp wrap_hue(h) when h >= 360, do: wrap_hue(h - 360)
  defp wrap_hue(h), do: h

  # Float modulo: returns a value in [0, divisor) for positive divisor.
  defp rem_float(n, divisor) when divisor > 0 do
    n - divisor * Float.floor(n / divisor)
  end
end
