defmodule Tymeslot.ThemeCustomizations.Defaults do
  @moduledoc """
  Pure functions for theme defaults and initialization logic.
  Handles theme-specific default configurations and customization initialization.
  """

  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

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
end
