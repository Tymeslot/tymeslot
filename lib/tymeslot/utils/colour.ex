defmodule Tymeslot.Utils.Colour do
  @moduledoc """
  Colour parsing, conversion, and contrast maths shared across the codebase.

  Three callers derive colours from user input and each needs the same
  primitives: `Tymeslot.ThemeCustomizations.PaletteDerivation` builds a
  booking-page palette from a seed, `Tymeslot.Emails.Shared.Styles.BrandPalette`
  builds the email brand family, and
  `Tymeslot.Integrations.Calendar.EventColour` matches CalDAV colours to the
  nearest palette anchor. Hex parsing living in three places is how one copy
  gains a fix the others silently don't, so it lives here instead.

  ## Conventions

  RGB channels are integers in `0..255`. HSL is `{hue, saturation, lightness}`
  where hue is degrees in `[0, 360)` and saturation and lightness are floats in
  `[0.0, 1.0]`. Hex input is tolerant — a leading `#` is optional, and 3-, 6-,
  and 8-character forms are all accepted (the alpha pair of an 8-character
  value is parsed and discarded). Hex output is always lowercase `#rrggbb`.

  ## Contrast

  `relative_luminance/1` and `contrast_ratio/2` implement the WCAG 2.1
  definitions, so a ratio can be compared directly against the published
  thresholds: 4.5 for normal text, 3.0 for large or bold text.
  """

  @typedoc "Red, green, and blue channels as integers in `0..255`."
  @type rgb :: {0..255, 0..255, 0..255}

  @typedoc "Hue in degrees `[0, 360)`, saturation and lightness in `[0.0, 1.0]`."
  @type hsl :: {float(), float(), float()}

  # WCAG 2.1 relative luminance coefficients and the sRGB linearisation
  # threshold below which the transfer function is linear rather than a power
  # curve.
  @luminance_weights {0.2126, 0.7152, 0.0722}
  @srgb_linear_threshold 0.03928

  @doc """
  Parses a hex colour into RGB channels, or `nil` when the input is not a
  valid hex colour.

  Every chunk must be purely hex digits (`0-9a-f`); a leading sign such as
  `+` or `-` is rejected rather than accepted by an underlying integer
  parser. For the 8-character form, the alpha pair must itself be valid hex
  or the whole value is rejected, even though the alpha channel is discarded.

  ## Examples

      iex> Tymeslot.Utils.Colour.parse_hex("#14b8a6")
      {20, 184, 166}

      iex> Tymeslot.Utils.Colour.parse_hex("fff")
      {255, 255, 255}

      iex> Tymeslot.Utils.Colour.parse_hex("not a colour")
      nil
  """
  @spec parse_hex(String.t() | nil) :: rgb() | nil
  def parse_hex(nil), do: nil

  def parse_hex(hex) when is_binary(hex) do
    hex
    |> String.trim()
    |> String.trim_leading("#")
    |> String.downcase()
    |> parse_digits()
  end

  def parse_hex(_other), do: nil

  defp parse_digits(<<r, g, b>>), do: parse_digits(<<r, r, g, g, b, b>>)

  defp parse_digits(<<digits::binary-6>>) do
    case Base.decode16(digits, case: :lower) do
      {:ok, <<r, g, b>>} -> {r, g, b}
      :error -> nil
    end
  end

  # 8-character form carries alpha in the final pair; the colour maths here is
  # opaque-only, so the alpha is checked for validity and then dropped.
  defp parse_digits(<<rgb::binary-6, aa::binary-2>>) do
    case Base.decode16(aa, case: :lower) do
      {:ok, _alpha} -> parse_digits(rgb)
      :error -> nil
    end
  end

  defp parse_digits(_other), do: nil

  @doc """
  Formats RGB channels as a lowercase `#rrggbb` string.

  ## Examples

      iex> Tymeslot.Utils.Colour.to_hex({20, 184, 166})
      "#14b8a6"
  """
  @spec to_hex(rgb()) :: String.t()
  def to_hex({r, g, b}), do: "#" <> byte_to_hex(r) <> byte_to_hex(g) <> byte_to_hex(b)

  @doc """
  Normalises any accepted hex form to lowercase `#rrggbb`, or `nil` when the
  input is not a valid hex colour.

  ## Examples

      iex> Tymeslot.Utils.Colour.normalise_hex("FFF")
      "#ffffff"
  """
  @spec normalise_hex(String.t() | nil) :: String.t() | nil
  def normalise_hex(hex) do
    case parse_hex(hex) do
      nil -> nil
      rgb -> to_hex(rgb)
    end
  end

  @doc "Converts RGB channels to HSL."
  @spec rgb_to_hsl(rgb()) :: hsl()
  def rgb_to_hsl({r, g, b}) do
    {rf, gf, bf} = {r / 255, g / 255, b / 255}
    max_c = max(max(rf, gf), bf)
    min_c = min(min(rf, gf), bf)
    lightness = (max_c + min_c) / 2
    delta = max_c - min_c

    {hue, saturation} = hue_and_saturation(delta, max_c, min_c, lightness, {rf, gf, bf})

    {hue, saturation, lightness}
  end

  defp hue_and_saturation(+0.0, _max_c, _min_c, _lightness, _channels), do: {0.0, 0.0}

  defp hue_and_saturation(delta, max_c, min_c, lightness, {rf, gf, bf}) do
    saturation =
      if lightness > 0.5,
        do: delta / (2 - max_c - min_c),
        else: delta / (max_c + min_c)

    hue_sextant =
      cond do
        max_c == rf -> rem_float((gf - bf) / delta, 6.0)
        max_c == gf -> (bf - rf) / delta + 2
        true -> (rf - gf) / delta + 4
      end

    {wrap_hue(hue_sextant * 60), saturation}
  end

  @doc "Converts HSL to RGB channels."
  @spec hsl_to_rgb(hsl()) :: rgb()
  def hsl_to_rgb({h, s, l}) do
    chroma = (1 - abs(2 * l - 1)) * s
    hue_prime = wrap_hue(h) / 60
    x = chroma * (1 - abs(rem_float(hue_prime, 2.0) - 1))
    lightness_offset = l - chroma / 2

    {r1, g1, b1} = chroma_channels(hue_prime, chroma, x)

    {to_byte(r1 + lightness_offset), to_byte(g1 + lightness_offset),
     to_byte(b1 + lightness_offset)}
  end

  defp chroma_channels(hue_prime, c, x) when hue_prime < 1, do: {c, x, 0.0}
  defp chroma_channels(hue_prime, c, x) when hue_prime < 2, do: {x, c, 0.0}
  defp chroma_channels(hue_prime, c, x) when hue_prime < 3, do: {0.0, c, x}
  defp chroma_channels(hue_prime, c, x) when hue_prime < 4, do: {0.0, x, c}
  defp chroma_channels(hue_prime, c, x) when hue_prime < 5, do: {x, 0.0, c}
  defp chroma_channels(_hue_prime, c, x), do: {c, 0.0, x}

  @doc """
  Converts a hex colour to HSL, or `nil` when the input is not a valid hex
  colour.
  """
  @spec hex_to_hsl(String.t() | nil) :: hsl() | nil
  def hex_to_hsl(hex) do
    case parse_hex(hex) do
      nil -> nil
      rgb -> rgb_to_hsl(rgb)
    end
  end

  @doc "Converts HSL to a lowercase `#rrggbb` string."
  @spec hsl_to_hex(hsl()) :: String.t()
  def hsl_to_hex(hsl), do: hsl |> hsl_to_rgb() |> to_hex()

  @doc "Converts HSL to a CSS `rgba()` string with the given alpha."
  @spec hsl_to_rgba(hsl(), float()) :: String.t()
  def hsl_to_rgba(hsl, alpha) do
    {r, g, b} = hsl_to_rgb(hsl)
    "rgba(#{r}, #{g}, #{b}, #{alpha})"
  end

  @doc """
  WCAG 2.1 relative luminance of a colour, in `[0.0, 1.0]`.

  Accepts RGB channels or any form `parse_hex/1` accepts; an unparseable hex
  string returns `0.0`.
  """
  @spec relative_luminance(rgb() | String.t()) :: float()
  def relative_luminance({r, g, b}) do
    {wr, wg, wb} = @luminance_weights
    wr * linearise(r) + wg * linearise(g) + wb * linearise(b)
  end

  def relative_luminance(hex) when is_binary(hex) do
    case parse_hex(hex) do
      nil -> 0.0
      rgb -> relative_luminance(rgb)
    end
  end

  defp linearise(channel) do
    c = channel / 255

    if c <= @srgb_linear_threshold do
      c / 12.92
    else
      :math.pow((c + 0.055) / 1.055, 2.4)
    end
  end

  @doc """
  WCAG 2.1 contrast ratio between two colours, from 1.0 (identical) to 21.0
  (black on white). Argument order does not matter.

  Compare against 4.5 for normal text and 3.0 for large or bold text.

  ## Examples

      iex> Tymeslot.Utils.Colour.contrast_ratio("#000000", "#ffffff")
      21.0
  """
  @spec contrast_ratio(rgb() | String.t(), rgb() | String.t()) :: float()
  def contrast_ratio(a, b) do
    la = relative_luminance(a)
    lb = relative_luminance(b)
    {lighter, darker} = {max(la, lb), min(la, lb)}

    (lighter + 0.05) / (darker + 0.05)
  end

  @doc """
  Darkens `hsl` in `step` decrements of lightness until it reaches at least
  `minimum` contrast against `reference`, giving up at a lightness floor of
  0.0 and returning the darkest value tried.

  Used to keep derived tokens legible for any seed colour an admin picks,
  without silently rejecting the colour.
  """
  @spec darken_until_contrast(hsl(), rgb() | String.t(), float(), float()) :: hsl()
  def darken_until_contrast(hsl, reference, minimum, step \\ 0.02)

  def darken_until_contrast({_h, _s, l} = hsl, _reference, _minimum, _step) when l <= 0.0,
    do: hsl

  def darken_until_contrast({h, s, l} = hsl, reference, minimum, step) do
    if contrast_ratio(hsl_to_hex(hsl), reference) >= minimum do
      hsl
    else
      darken_until_contrast({h, s, clamp(l - step, 0.0, 1.0)}, reference, minimum, step)
    end
  end

  @doc """
  Lightens `hsl` in `step` increments of lightness until it reaches at least
  `minimum` contrast against `reference`, giving up at a lightness ceiling of
  1.0 and returning the lightest value tried.

  The mirror of `darken_until_contrast/4`, for the case where `reference` is a
  dark ink: contrast then grows as the surface gets lighter, so darkening it
  would walk the wrong way.
  """
  @spec lighten_until_contrast(hsl(), rgb() | String.t(), float(), float()) :: hsl()
  def lighten_until_contrast(hsl, reference, minimum, step \\ 0.02)

  def lighten_until_contrast({_h, _s, l} = hsl, _reference, _minimum, _step) when l >= 1.0,
    do: hsl

  def lighten_until_contrast({h, s, l} = hsl, reference, minimum, step) do
    if contrast_ratio(hsl_to_hex(hsl), reference) >= minimum do
      hsl
    else
      lighten_until_contrast({h, s, clamp(l + step, 0.0, 1.0)}, reference, minimum, step)
    end
  end

  @doc "Clamps `n` into the inclusive range `lo..hi`."
  @spec clamp(number(), number(), number()) :: number()
  def clamp(n, lo, _hi) when n < lo, do: lo
  def clamp(n, _lo, hi) when n > hi, do: hi
  def clamp(n, _lo, _hi), do: n

  @doc "Wraps a hue in degrees into `[0, 360)`."
  @spec wrap_hue(number()) :: float()
  def wrap_hue(h) when h < 0, do: wrap_hue(h + 360)
  def wrap_hue(h) when h >= 360, do: wrap_hue(h - 360)
  def wrap_hue(h), do: h * 1.0

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

  # Float modulo returning a value in `[0, divisor)` for a positive divisor.
  defp rem_float(n, divisor) when divisor > 0 do
    n - divisor * Float.floor(n / divisor)
  end
end
