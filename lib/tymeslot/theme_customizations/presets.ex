defmodule Tymeslot.ThemeCustomizations.Presets do
  @moduledoc """
  The preset catalogue and the lookups over it.

  Each kind of preset lives in a module of its own under `presets/`
  (`Presets.ColourSchemes`, `Presets.Gradients`, `Presets.Images`,
  `Presets.Videos`, `Presets.Covers` (cover images), `Presets.Accents`,
  `Presets.Fonts`), which holds the data and exports `all/0`. Everything
  outside the catalogue reads presets through this module: `find_preset_by_id/2`
  and `take/2` for any kind, and the per-kind getters. A new kind is a module
  under `presets/` and one entry in `kinds/0`.
  """

  alias Tymeslot.ThemeCustomizations.Presets.Accents
  alias Tymeslot.ThemeCustomizations.Presets.ColourSchemes
  alias Tymeslot.ThemeCustomizations.Presets.Covers
  alias Tymeslot.ThemeCustomizations.Presets.Fonts
  alias Tymeslot.ThemeCustomizations.Presets.Gradients
  alias Tymeslot.ThemeCustomizations.Presets.Images
  alias Tymeslot.ThemeCustomizations.Presets.Videos

  @type colours :: ColourSchemes.colours()
  @type color_scheme_preset :: ColourSchemes.preset()
  @type gradient_preset :: Gradients.preset()
  @type image_preset :: Images.preset()
  @type video_preset :: Videos.preset()
  @type cover_preset :: Covers.cover_preset()
  @type accent_preset :: Accents.preset()
  @type font_preset :: Fonts.preset()

  @type preset ::
          color_scheme_preset()
          | gradient_preset()
          | image_preset()
          | video_preset()
          | cover_preset()
          | accent_preset()
          | font_preset()

  @typedoc "A kind of preset, as `find_preset_by_id/2` and `take/2` name it."
  @type kind :: :color_scheme | :gradient | :video | :image | :cover | :accent | :font

  @doc """
  Gets all color scheme definitions.
  """
  @spec get_color_schemes() :: %{String.t() => color_scheme_preset()}
  def get_color_schemes, do: ColourSchemes.all()

  @doc """
  Gets all gradient preset definitions.
  """
  @spec get_gradient_presets() :: %{String.t() => gradient_preset()}
  def get_gradient_presets, do: Gradients.all()

  @doc """
  Gets all video preset definitions.
  """
  @spec get_video_presets() :: %{String.t() => video_preset()}
  def get_video_presets, do: Videos.all()

  @doc """
  Gets all image preset definitions.
  """
  @spec get_image_presets() :: %{String.t() => image_preset()}
  def get_image_presets, do: Images.all()

  @doc """
  The presets of one kind that `ids` names, as `{id, preset}` in the order
  given. An id the catalogue does not hold is left out.
  """
  @spec take(kind(), [String.t()]) :: [{String.t(), preset()}]
  def take(kind, ids) do
    Enum.flat_map(ids, fn id ->
      case find_preset_by_id(kind, id) do
        nil -> []
        preset -> [{id, preset}]
      end
    end)
  end

  @doc """
  Finds a preset by kind and id; `nil` for an unknown kind or id.
  """
  @spec find_preset_by_id(kind() | atom(), String.t()) :: preset() | nil
  def find_preset_by_id(kind, id) do
    case Map.fetch(kinds(), kind) do
      {:ok, module} -> Map.get(module.all(), id)
      :error -> nil
    end
  end

  # Kind -> the module holding its presets. A function body rather than a
  # module attribute, so the kind modules stay runtime references (see
  # `Tymeslot.Themes.Catalog`).
  defp kinds do
    %{
      accent: Accents,
      color_scheme: ColourSchemes,
      font: Fonts,
      gradient: Gradients,
      image: Images,
      video: Videos,
      cover: Covers
    }
  end
end
