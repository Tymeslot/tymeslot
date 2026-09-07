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
end
