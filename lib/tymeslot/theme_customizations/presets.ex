defmodule Tymeslot.ThemeCustomizations.Presets do
  @moduledoc """
  Pure functions for preset management and lookups.
  Handles color schemes, gradients, images, and video presets.
  """

  alias Tymeslot.DatabaseSchemas.ThemeCustomizationSchema

  @doc """
  Gets all color scheme definitions.
  """
  @spec get_color_schemes() :: map()
  def get_color_schemes do
    ThemeCustomizationSchema.color_scheme_definitions()
  end

  @doc """
  Gets all gradient preset definitions.
  """
  @spec get_gradient_presets() :: map()
  def get_gradient_presets do
    ThemeCustomizationSchema.gradient_presets()
  end

  @doc """
  Gets all video preset definitions.
  """
  @spec get_video_presets() :: map()
  def get_video_presets do
    ThemeCustomizationSchema.video_presets()
  end

  @doc """
  Gets all image preset definitions.
  """
  @spec get_image_presets() :: map()
  def get_image_presets do
    ThemeCustomizationSchema.image_presets()
  end

  @doc """
  Gets all presets organized by type.
  """
  @spec get_all_presets() :: %{
          required(:color_schemes) => map(),
          required(:gradients) => map(),
          required(:videos) => map(),
          required(:images) => map()
        }
  def get_all_presets do
    %{
      color_schemes: get_color_schemes(),
      gradients: get_gradient_presets(),
      videos: get_video_presets(),
      images: get_image_presets()
    }
  end

  @doc """
  Finds a specific preset by type and ID.
  """
  @spec find_preset_by_id(:color_scheme | :gradient | :video | :image, String.t()) :: map() | nil
  def find_preset_by_id(preset_type, preset_id) do
    case preset_type do
      :color_scheme -> Map.get(get_color_schemes(), preset_id)
      :gradient -> Map.get(get_gradient_presets(), preset_id)
      :video -> Map.get(get_video_presets(), preset_id)
      :image -> Map.get(get_image_presets(), preset_id)
      _ -> nil
    end
  end

  @doc """
  Validates that a preset exists for the given type and ID.
  """
  @spec validate_preset_exists(:color_scheme | :gradient | :video | :image, String.t()) ::
          :ok | {:error, :preset_not_found}
  def validate_preset_exists(preset_type, preset_id) do
    case find_preset_by_id(preset_type, preset_id) do
      nil -> {:error, :preset_not_found}
      _preset -> :ok
    end
  end

  @doc """
  Gets preset by background type and value.
  """
  @spec get_preset_by_background(String.t(), String.t() | nil) :: map() | nil
  def get_preset_by_background(background_type, background_value) do
    case background_type do
      "gradient" ->
        find_preset_by_id(:gradient, background_value)

      "image" ->
        if background_value && String.starts_with?(background_value, "preset:") do
          find_preset_by_id(:image, background_value)
        else
          nil
        end

      "video" ->
        if background_value && String.starts_with?(background_value, "preset:") do
          find_preset_by_id(:video, background_value)
        else
          nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Lists all available preset IDs for a given type.
  """
  @spec list_preset_ids(:color_scheme | :gradient | :video | :image) :: [String.t()]
  def list_preset_ids(preset_type) do
    case preset_type do
      :color_scheme -> Map.keys(get_color_schemes())
      :gradient -> Map.keys(get_gradient_presets())
      :video -> Map.keys(get_video_presets())
      :image -> Map.keys(get_image_presets())
      _ -> []
    end
  end

  @doc """
  Gets preset metadata (name, description) without the full data.
  """
  @spec get_preset_metadata(:color_scheme | :gradient | :video | :image, String.t()) ::
          map() | nil
  def get_preset_metadata(preset_type, preset_id) do
    case find_preset_by_id(preset_type, preset_id) do
      nil ->
        nil

      preset ->
        %{
          name: Map.get(preset, :name),
          description: Map.get(preset, :description),
          id: preset_id,
          type: preset_type
        }
    end
  end

  @doc """
  Checks if a background value represents a preset.
  """
  @spec preset_value?(String.t() | nil) :: boolean()
  def preset_value?(background_value) do
    String.starts_with?(background_value || "", "preset:")
  end

  @doc """
  Extracts preset ID from a preset value string.
  """
  @spec extract_preset_id(String.t() | any()) :: String.t() | nil
  def extract_preset_id(preset_value) when is_binary(preset_value) do
    if preset_value?(preset_value) do
      String.replace_prefix(preset_value, "preset:", "")
    else
      preset_value
    end
  end

  def extract_preset_id(_), do: nil

  @doc """
  Formats a preset ID as a preset value string.
  """
  @spec format_as_preset_value(String.t() | any()) :: String.t() | nil
  def format_as_preset_value(preset_id) when is_binary(preset_id) do
    if preset_value?(preset_id) do
      preset_id
    else
      "preset:#{preset_id}"
    end
  end

  def format_as_preset_value(_), do: nil

  @doc """
  Gets recommended presets for a theme.
  """
  @spec get_recommended_presets_for_theme(String.t()) :: map()
  def get_recommended_presets_for_theme(theme_id) do
    case theme_id do
      "1" ->
        # Quill theme recommendations
        %{
          gradients: ["gradient_1", "gradient_2", "gradient_3"],
          videos: [],
          images: ["image_1", "image_2"]
        }

      "2" ->
        # Rhythm theme recommendations
        %{
          gradients: ["gradient_1", "gradient_4", "gradient_5"],
          videos: ["preset:rhythm-default", "preset:abstract-waves"],
          images: ["image_3", "image_4"]
        }

      _ ->
        %{gradients: [], videos: [], images: []}
    end
  end
end
