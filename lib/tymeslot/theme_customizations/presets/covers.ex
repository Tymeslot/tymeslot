defmodule Tymeslot.ThemeCustomizations.Presets.Covers do
  @moduledoc """
  The cover presets: the wide image across the top of a booking page, for a
  theme with an `Options.Cover` group, which lists the ids it offers.

  Each cover is `%{name:, src:, thumb:}`, `src` and `thumb` its public paths.
  The first four reuse the shipped background images under
  `priv/static/images/themes/backgrounds/` (Pixabay Content Licence, like
  every shipped background) rather than copying them, under the background
  presets' ids and names, so an organiser sees the same image under the same
  name in both pickers. A cover of its own lives under
  `priv/static/images/themes/covers/` (`botanical`, `studio-light`,
  `paper-texture`), a Pixabay image at the background images' size, with its
  source page in `source`.
  """

  @typedoc "A cover preset."
  @type cover_preset :: %{
          required(:name) => String.t(),
          required(:src) => String.t(),
          required(:thumb) => String.t(),
          optional(:source) => String.t()
        }

  @backgrounds "/images/themes/backgrounds/"
  @covers_dir "/images/themes/covers/"

  @covers %{
    "elegant-still-life" => %{
      name: "Elegant Still Life",
      src: @backgrounds <> "elegant-still-life.webp",
      thumb: @backgrounds <> "elegant-still-life-thumbnail.webp"
    },
    "artistic-studio" => %{
      name: "Artistic Studio",
      src: @backgrounds <> "artistic-studio.webp",
      thumb: @backgrounds <> "artistic-studio-thumbnail.webp"
    },
    "ocean-sunset" => %{
      name: "Ocean Sunset",
      src: @backgrounds <> "ocean-sunset.webp",
      thumb: @backgrounds <> "ocean-sunset-thumbnail.webp"
    },
    "rustic-farmhouse" => %{
      name: "Rustic Farmhouse",
      src: @backgrounds <> "rustic-farmhouse.webp",
      thumb: @backgrounds <> "rustic-farmhouse-thumbnail.webp"
    },
    "botanical" => %{
      name: "Botanical",
      src: @covers_dir <> "botanical.webp",
      thumb: @covers_dir <> "botanical-thumbnail.webp",
      source: "https://pixabay.com/photos/eucalyptus-flowers-floral-leaf-3854084/"
    },
    "studio-light" => %{
      name: "Studio Light",
      src: @covers_dir <> "studio-light.webp",
      thumb: @covers_dir <> "studio-light-thumbnail.webp",
      source: "https://pixabay.com/photos/natural-nature-landscape-9954257/"
    },
    "paper-texture" => %{
      name: "Paper Texture",
      src: @covers_dir <> "paper-texture.webp",
      thumb: @covers_dir <> "paper-texture-thumbnail.webp",
      source: "https://pixabay.com/photos/paper-white-gray-handmade-1332019/"
    }
  }

  @doc "Every cover preset, keyed by id."
  @spec all() :: %{String.t() => cover_preset()}
  def all, do: @covers
end
