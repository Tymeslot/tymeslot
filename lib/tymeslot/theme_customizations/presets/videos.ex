defmodule Tymeslot.ThemeCustomizations.Presets.Videos do
  @moduledoc """
  The background video presets. The files ship under
  `priv/static/videos/backgrounds/` and their posters under
  `priv/static/images/ui/posters/`; `Options.Background` builds the URLs. Read
  through `Tymeslot.ThemeCustomizations.Presets`.
  """

  @type preset :: %{
          required(:name) => String.t(),
          required(:file) => String.t(),
          required(:thumbnail) => String.t(),
          required(:poster) => String.t(),
          required(:description) => String.t()
        }

  @videos %{
    "preset:rhythm-default" => %{
      name: "Rhythm Default",
      file: "rhythm-background-desktop.webm",
      thumbnail: "rhythm-background-thumbnail.jpg",
      poster: "rhythm-background-poster.jpg",
      description: "Default Rhythm theme video"
    },
    "preset:blue-wave" => %{
      name: "Blue Wave",
      file: "blue-wave-desktop.mp4",
      thumbnail: "blue-wave-thumbnail.jpg",
      poster: "blue-wave-poster.jpg",
      description: "Flowing blue wave animation"
    },
    "preset:dancing-girl" => %{
      name: "Dancing Girl",
      file: "dancing-girl-desktop.mp4",
      thumbnail: "dancing-girl-thumbnail.jpg",
      poster: "dancing-girl-poster.jpg",
      description: "Elegant dancing silhouette"
    },
    "preset:leaves" => %{
      name: "Falling Leaves",
      file: "leaves-desktop.mp4",
      thumbnail: "leaves-thumbnail.jpg",
      poster: "leaves-poster.jpg",
      description: "Peaceful autumn leaves falling"
    },
    "preset:light-green" => %{
      name: "Light Green",
      file: "light-green-desktop.mp4",
      thumbnail: "light-green-thumbnail.jpg",
      poster: "light-green-poster.jpg",
      description: "Soothing light green abstract"
    },
    "preset:space" => %{
      name: "Space Journey",
      file: "space-desktop.mp4",
      thumbnail: "space-thumbnail.jpg",
      poster: "space-poster.jpg",
      description: "Cosmic space exploration"
    }
  }

  @doc "Every background video, keyed by id."
  @spec all() :: %{String.t() => preset()}
  def all, do: @videos
end
