defmodule Tymeslot.ThemeCustomizations.Css do
  @moduledoc """
  Pure CSS and palette resolution for theme customizations.

  Stateless functions that turn a colour scheme, gradient preset, or full
  customisation into the CSS variable strings consumed by the booking themes.
  No database access and no filesystem side effects live here — palette
  derivation is delegated to `PaletteDerivation` and preset lookups to
  `Presets`, mirroring how the context orchestrated these calls previously.
  """

  alias Tymeslot.ThemeCustomizations.Capability
  alias Tymeslot.ThemeCustomizations.ContrastTokens
  alias Tymeslot.ThemeCustomizations.PaletteDerivation
  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias Tymeslot.ThemeCustomizations.Validation

  @hex_color_regex ~r/^#[0-9A-Fa-f]{6}$/

  @doc """
  Gets the CSS variables for a colour scheme.

  Accepts either a scheme ID (string/atom — looked up in the static preset map)
  or a customisation map. The map form supports the "custom" scheme: when
  `color_scheme == "custom"`, the palette is derived from `custom_palette_seed`
  via `PaletteDerivation.derive_palette/1` instead of preset lookup.
  """
  @spec get_color_scheme_css(String.t() | atom() | map()) :: String.t() | nil
  def get_color_scheme_css(customization) when is_map(customization) do
    case resolve_palette(customization) do
      nil -> nil
      %{colors: colors} -> format_palette_css(colors)
    end
  end

  def get_color_scheme_css(scheme_id) when is_binary(scheme_id) or is_atom(scheme_id) do
    case Presets.find_preset_by_id(:color_scheme, scheme_id) do
      nil -> nil
      %{colors: colors} -> format_palette_css(colors)
    end
  end

  @doc """
  Gets the CSS for a gradient preset.
  """
  @spec get_gradient_css(String.t() | atom()) :: String.t() | nil
  def get_gradient_css(gradient_id) do
    case Presets.find_preset_by_id(:gradient, gradient_id) do
      nil -> nil
      %{value: value} -> value
    end
  end

  @doc """
  Generates the full theme CSS variables string (capability-based + legacy
  fallback) for a given theme and customisation map.
  """
  @spec generate_theme_css(String.t(), map()) :: String.t()
  def generate_theme_css(theme_id, customization_map) do
    theme_id
    |> Capability.generate_css(customization_map)
    |> Validation.sanitize_css()
  end

  @doc """
  Resolves the active colour scheme for a customisation, returning the same
  `%{name, colors}` shape used by both presets and palette derivation.

  When `custom_palette_seed` is present on the customisation, the palette is
  derived from that seed; otherwise the `color_scheme` field is looked up in
  the provided `presets.color_schemes` map. Returns `nil` if neither resolves
  to a known scheme.
  """
  @spec resolve_active_scheme(ThemeCustomizationSchema.t() | map(), map()) :: map() | nil
  def resolve_active_scheme(customization, presets) do
    seed = get_seed(customization)

    if is_binary(seed) and seed != "" do
      PaletteDerivation.derive_palette(seed)
    else
      scheme_id = get_scheme_id(customization)
      Map.get(presets.color_schemes, scheme_id)
    end
  end

  @doc """
  Validates a custom palette seed hex string.

  The seed must be a 6-character hex string (with leading `#`); otherwise an
  error tuple is returned.
  """
  @spec validate_seed_hex(term()) :: :ok | {:error, String.t()}
  def validate_seed_hex(seed) when is_binary(seed) do
    if String.match?(seed, @hex_color_regex) do
      :ok
    else
      {:error, "Custom palette seed must be a 6-character hex colour"}
    end
  end

  def validate_seed_hex(_other),
    do: {:error, "Custom palette seed must be a 6-character hex colour"}

  @doc """
  Extracts the custom palette seed from a customisation schema or map.
  """
  @spec get_seed(ThemeCustomizationSchema.t() | map()) :: String.t() | nil
  def get_seed(%ThemeCustomizationSchema{custom_palette_seed: seed}), do: seed

  def get_seed(map) when is_map(map) do
    Map.get(map, :custom_palette_seed) || Map.get(map, "custom_palette_seed")
  end

  @doc """
  Extracts the colour scheme ID from a customisation schema or map.
  """
  @spec get_scheme_id(ThemeCustomizationSchema.t() | map()) :: String.t() | nil
  def get_scheme_id(%ThemeCustomizationSchema{color_scheme: s}), do: s

  def get_scheme_id(map) when is_map(map) do
    Map.get(map, :color_scheme) || Map.get(map, "color_scheme")
  end

  # --- Private helpers ----------------------------------------------------

  defp resolve_palette(customization) do
    seed = get_seed(customization)
    scheme_id = get_scheme_id(customization)

    cond do
      is_binary(seed) and seed != "" -> PaletteDerivation.derive_palette(seed)
      is_binary(scheme_id) -> Presets.find_preset_by_id(:color_scheme, scheme_id)
      true -> nil
    end
  end

  defp format_palette_css(colors) do
    colors
    |> Map.merge(contrast_tokens(colors))
    |> Enum.map_join("\n", fn {key, value} ->
      "--theme-#{String.replace(to_string(key), "_", "-")}: #{value};"
    end)
  end

  # Filled controls put text on top of the palette rather than beside it, so
  # they need an ink and a surface that pass AA together. See
  # `ContrastTokens` for why the palette's own colours are left alone.
  defp contrast_tokens(colors) do
    ContrastTokens.derive(colors) || %{}
  end
end
