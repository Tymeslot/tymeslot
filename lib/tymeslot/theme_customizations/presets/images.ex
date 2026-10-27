defmodule Tymeslot.ThemeCustomizations.Presets.Images do
  @moduledoc """
  The background image presets. The files and their thumbnails ship under
  `priv/static/images/themes/backgrounds/`, the one directory every preset
  image is served from (`url/1`; the cover presets reuse some of them).
  Read through `Tymeslot.ThemeCustomizations.Presets`.
  """

  @type preset :: %{
          required(:name) => String.t(),
          required(:file) => String.t(),
          required(:thumbnail) => String.t(),
          required(:description) => String.t()
        }

  @dir "/images/themes/backgrounds/"

  @images %{
    "preset:artistic-studio" => %{
      name: "Artistic Studio",
      file: "artistic-studio.webp",
      thumbnail: "artistic-studio-thumbnail.webp",
      description: "Creative artistic workspace scene"
    },
    "preset:rustic-farmhouse" => %{
      name: "Rustic Farmhouse",
      file: "rustic-farmhouse.webp",
      thumbnail: "rustic-farmhouse-thumbnail.webp",
      description: "Cozy farmhouse still life with rustic charm"
    },
    "preset:space-satellite" => %{
      name: "Space Satellite",
      file: "space-satellite.webp",
      thumbnail: "space-satellite-thumbnail.webp",
      description: "Modern satellite technology in space"
    },
    "preset:elegant-still-life" => %{
      name: "Elegant Still Life",
      file: "elegant-still-life.webp",
      thumbnail: "elegant-still-life-thumbnail.webp",
      description: "Sophisticated still life composition"
    },
    "preset:ocean-sunset" => %{
      name: "Ocean Sunset",
      file: "ocean-sunset.webp",
      thumbnail: "ocean-sunset-thumbnail.webp",
      description: "Peaceful ocean sunset with surfer silhouette"
    }
  }

  @doc "Every background image, keyed by id."
  @spec all() :: %{String.t() => preset()}
  def all, do: @images

  @doc "The public URL of a preset image file (or its thumbnail)."
  @spec url(String.t()) :: String.t()
  def url(file) when is_binary(file), do: @dir <> file
end
