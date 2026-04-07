defmodule Tymeslot.ThemeCustomizations.Presets do
  @moduledoc """
  Pure functions for preset management and lookups.
  Handles color schemes, gradients, images, and video presets.
  """

  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  @type color_scheme_preset :: %{
          required(:name) => String.t(),
          required(:colors) => %{atom() => String.t()}
        }
  @type gradient_preset :: %{required(:name) => String.t(), required(:value) => String.t()}
  @type image_preset :: %{
          required(:name) => String.t(),
          required(:file) => String.t(),
          required(:thumbnail) => String.t(),
          required(:description) => String.t()
        }
  @type video_preset :: %{
          required(:name) => String.t(),
          required(:file) => String.t(),
          required(:thumbnail) => String.t(),
          required(:poster) => String.t(),
          required(:description) => String.t()
        }
  @type preset :: color_scheme_preset() | gradient_preset() | image_preset() | video_preset()
  @type preset_metadata :: %{
          required(:name) => String.t() | nil,
          required(:description) => String.t() | nil,
          required(:id) => String.t(),
          required(:type) => :color_scheme | :gradient | :video | :image
        }
  @type theme_recommendations :: %{
          required(:gradients) => [String.t()],
          required(:videos) => [String.t()],
          required(:images) => [String.t()]
        }
  @type all_presets :: %{
          required(:color_schemes) => %{String.t() => color_scheme_preset()},
          required(:gradients) => %{String.t() => gradient_preset()},
          required(:videos) => %{String.t() => video_preset()},
          required(:images) => %{String.t() => image_preset()}
        }

  @doc """
  Gets all color scheme definitions.
  """
  @spec get_color_schemes() :: %{String.t() => color_scheme_preset()}
  def get_color_schemes do
    ThemeCustomizationSchema.color_scheme_definitions()
  end

  @doc """
  Gets all gradient preset definitions.
  """
  @spec get_gradient_presets() :: %{String.t() => gradient_preset()}
  def get_gradient_presets do
    ThemeCustomizationSchema.gradient_presets()
  end

  @doc """
  Gets all video preset definitions.
  """
  @spec get_video_presets() :: %{String.t() => video_preset()}
  def get_video_presets do
    ThemeCustomizationSchema.video_presets()
  end

  @doc """
  Gets all image preset definitions.
  """
  @spec get_image_presets() :: %{String.t() => image_preset()}
  def get_image_presets do
    ThemeCustomizationSchema.image_presets()
  end

  @doc """
  Gets all presets organized by type.
  """
  @spec get_all_presets() :: all_presets()
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
  @spec find_preset_by_id(:color_scheme | :gradient | :video | :image, String.t()) ::
          preset() | nil
  def find_preset_by_id(preset_type, preset_id) do
    case preset_type do
      :color_scheme -> Map.get(get_color_schemes(), preset_id)
      :gradient -> Map.get(get_gradient_presets(), preset_id)
      :video -> Map.get(get_video_presets(), preset_id)
      :image -> Map.get(get_image_presets(), preset_id)
      _other_type -> nil
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
  @spec get_preset_by_background(String.t(), String.t() | nil) :: preset() | nil
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

      _other_category ->
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
      _other_type -> []
    end
  end

  @doc """
  Gets preset metadata (name, description) without the full data.
  """
  @spec get_preset_metadata(:color_scheme | :gradient | :video | :image, String.t()) ::
          preset_metadata() | nil
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

  def extract_preset_id(_value), do: nil

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

  def format_as_preset_value(_value), do: nil

  @doc """
  Gets recommended presets for a theme.
  """
  @spec get_recommended_presets_for_theme(String.t()) :: theme_recommendations()
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

      _other_theme ->
        %{gradients: [], videos: [], images: []}
    end
  end
end
