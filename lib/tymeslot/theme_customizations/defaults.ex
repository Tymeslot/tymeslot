defmodule Tymeslot.ThemeCustomizations.Defaults do
  @moduledoc """
  Pure functions for theme defaults and initialization logic.
  Handles theme-specific default configurations and customization initialization.
  """

  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias Tymeslot.Themes.Registry

  @doc """
  Gets the default configuration for a specific theme.
  """
  @spec get_theme_defaults(String.t()) :: map()
  def get_theme_defaults(theme_id) do
    case theme_id do
      "1" ->
        # Quill theme - glass morphism with gradient
        %{
          color_scheme: "default",
          background_type: "gradient",
          background_value: "gradient_1"
        }

      "2" ->
        # Rhythm theme - video background
        %{
          color_scheme: "default",
          background_type: "video",
          background_value: "preset:rhythm-default"
        }

      _unknown_theme ->
        # Default fallback
        %{
          color_scheme: "default",
          background_type: "gradient",
          background_value: "gradient_1"
        }
    end
  end

  @doc """
  Builds initial customization from saved data or defaults.
  """
  @spec build_initial_customization(integer(), String.t(), ThemeCustomizationSchema.t() | nil) ::
          ThemeCustomizationSchema.t()
  def build_initial_customization(profile_id, theme_id, saved_customization) do
    theme_defaults = get_theme_defaults(theme_id)

    case saved_customization do
      nil ->
        %ThemeCustomizationSchema{
          profile_id: profile_id,
          theme_id: theme_id,
          color_scheme: theme_defaults.color_scheme,
          background_type: theme_defaults.background_type,
          background_value: theme_defaults.background_value,
          background_image_path: nil,
          background_video_path: nil
        }

      existing ->
        existing
    end
  end

  @doc """
  Creates a fallback customization with theme defaults.
  Used when no customization exists and we need default values.
  """
  @spec get_fallback_customization(String.t()) :: ThemeCustomizationSchema.t()
  def get_fallback_customization(theme_id) do
    theme_defaults = get_theme_defaults(theme_id)

    %ThemeCustomizationSchema{
      profile_id: nil,
      theme_id: theme_id,
      color_scheme: theme_defaults.color_scheme,
      background_type: theme_defaults.background_type,
      background_value: theme_defaults.background_value,
      background_image_path: nil,
      background_video_path: nil
    }
  end

  @doc """
  Merges a customization with theme defaults for missing fields.
  """
  @spec merge_with_defaults(ThemeCustomizationSchema.t(), String.t()) ::
          ThemeCustomizationSchema.t()
  def merge_with_defaults(customization, theme_id) do
    theme_defaults = get_theme_defaults(theme_id)

    %{
      customization
      | color_scheme: non_empty(customization.color_scheme) || theme_defaults.color_scheme,
        background_type:
          non_empty(customization.background_type) || theme_defaults.background_type,
        background_value:
          non_empty(customization.background_value) || theme_defaults.background_value
    }
  end

  defp non_empty(""), do: nil
  defp non_empty(value), do: value

  @doc """
  Determines if a theme supports specific customization features.
  """
  @spec theme_supports_feature?(String.t(), atom()) :: boolean()
  def theme_supports_feature?(theme_id, feature) do
    case Registry.get_theme_by_id(theme_id) do
      {:ok, theme} -> Map.get(theme.features, registry_feature_key(feature), false)
      _other -> false
    end
  end

  defp registry_feature_key(:video_backgrounds), do: :supports_video_background
  defp registry_feature_key(:image_backgrounds), do: :supports_image_background
  defp registry_feature_key(:gradient_backgrounds), do: :supports_gradient_background
  defp registry_feature_key(:color_backgrounds), do: :supports_color_background
  defp registry_feature_key(_unknown), do: nil

  @doc """
  Gets the recommended background type for a theme.
  """
  @spec get_recommended_background_type(String.t()) :: String.t()
  def get_recommended_background_type(theme_id) do
    theme_defaults = get_theme_defaults(theme_id)
    theme_defaults.background_type
  end
end
