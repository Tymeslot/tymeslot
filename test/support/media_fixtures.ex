defmodule Tymeslot.Test.MediaFixtures do
  @moduledoc """
  Real, decodable images and videos for upload tests.

  Stored uploads are re-encoded (images) or walked box by box (videos) to
  strip their metadata, so a file that only carries the right magic bytes is
  refused. The fixtures under `test/support/fixtures/media/` carry the
  metadata a phone writes:

    * `gps_portrait.jpg`: 32x16 pixels, EXIF Orientation 6 (displayed 16x32),
      GPS coordinates, make, model, serial number and capture time;
    * `gps.webp`, `gps.png`: EXIF GPS and device details; the PNG adds a
      `tEXt` comment and XMP;
    * `animated.gif`, `animated.webp`: three 16x8 frames, with a GIF comment
      and XMP;
    * `gps.mp4`: `©xyz`, 3GPP `loci` and Apple keyed location, a title, and
      creation times in the movie, track and media headers;
    * `gps.webm`: location, title and device tags, and `DateUTC`.
  """

  alias ExUnit.Callbacks
  alias Vix.Vips.Image, as: VipsImage

  @dir Path.expand("fixtures/media", __DIR__)

  # The libvips header fields that hold metadata read from the file.
  @metadata_field ~r/\A(exif-|xmp-data\z|iptc-data\z|png-comment-|gif-comment\z|orientation\z)/

  # A complete 1x1 RGBA PNG: signature, IHDR, IDAT and IEND.
  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
         6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 11, 73, 68, 65, 84, 8, 153, 99, 96, 0, 2, 0, 0, 5,
         0, 1, 34, 38, 10, 75, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

  @doc "The absolute path of a fixture under `test/support/fixtures/media/`."
  @spec path(String.t()) :: Path.t()
  def path(name), do: Path.join(@dir, name)

  @doc "The contents of a fixture under `test/support/fixtures/media/`."
  @spec read!(String.t()) :: binary()
  def read!(name), do: File.read!(path(name))

  @doc """
  Copies a fixture to a fresh temporary file and returns its path, for code
  that edits or moves the file it is given. Removed when the test exits.
  """
  @spec temp_copy!(String.t()) :: Path.t()
  def temp_copy!(name) do
    temp =
      Path.join(
        System.tmp_dir!(),
        "tymeslot_media_#{System.unique_integer([:positive])}#{Path.extname(name)}"
      )

    File.cp!(path(name), temp)
    Callbacks.on_exit(fn -> File.rm(temp) end)
    temp
  end

  @doc """
  The metadata fields libvips reads from an image's `contents`, for asserting
  what a stored or served file still carries independently of the code that
  strips it.
  """
  @spec image_metadata_fields(binary()) :: [String.t()]
  def image_metadata_fields(contents) do
    {:ok, fields} = contents |> image!() |> VipsImage.header_field_names()
    Enum.filter(fields, &(&1 =~ @metadata_field))
  end

  @doc "The width and height of the image whose `contents` are given."
  @spec image_dimensions(binary()) :: {pos_integer(), pos_integer()}
  def image_dimensions(contents) do
    image = image!(contents)
    {VipsImage.width(image), VipsImage.height(image)}
  end

  # From memory rather than by path: libvips caches loads by file name, and a
  # file stripped in place keeps its name.
  defp image!(contents) do
    {:ok, image} = VipsImage.new_from_buffer(contents)
    image
  end

  @doc "A minimal, complete PNG: one transparent pixel."
  @spec png() :: binary()
  def png, do: @png
end
