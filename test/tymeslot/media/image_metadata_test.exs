defmodule Tymeslot.Media.ImageMetadataTest do
  use ExUnit.Case, async: true

  @moduletag :security
  @moduletag :unit

  alias Tymeslot.Media.ImageMetadata
  alias Tymeslot.Test.MediaFixtures
  alias Vix.Vips.Image, as: VipsImage

  @tag :tmp_dir
  test "removes the GPS location and device details from a phone JPEG", %{tmp_dir: tmp_dir} do
    source = MediaFixtures.path("gps_portrait.jpg")
    dest = Path.join(tmp_dir, "avatar.jpg")

    assert "exif-ifd3-GPSLatitude" in MediaFixtures.image_metadata_fields(File.read!(source))

    assert :ok = ImageMetadata.strip(source, dest, ".jpg")

    assert MediaFixtures.image_metadata_fields(File.read!(dest)) == []
    stored = File.read!(dest)
    refute stored =~ "Model-X"
    refute stored =~ "SN12345"
  end

  @tag :tmp_dir
  test "turns a portrait photo upright before dropping its orientation", %{tmp_dir: tmp_dir} do
    dest = Path.join(tmp_dir, "avatar.jpg")

    assert :ok = ImageMetadata.strip(MediaFixtures.path("gps_portrait.jpg"), dest, ".jpg")

    # Stored 32x16 with EXIF Orientation 6: displayed, and now stored, 16x32.
    assert MediaFixtures.image_dimensions(File.read!(dest)) == {16, 32}
  end

  @tag :tmp_dir
  test "removes EXIF from a WebP", %{tmp_dir: tmp_dir} do
    dest = Path.join(tmp_dir, "background.webp")

    assert :ok = ImageMetadata.strip(MediaFixtures.path("gps.webp"), dest, ".webp")

    assert MediaFixtures.image_metadata_fields(File.read!(dest)) == []
    refute File.read!(dest) =~ "Model-X"
    assert MediaFixtures.image_dimensions(File.read!(dest)) == {32, 16}
  end

  @tag :tmp_dir
  test "removes EXIF, XMP and text chunks from a PNG", %{tmp_dir: tmp_dir} do
    dest = Path.join(tmp_dir, "avatar.png")

    assert :ok = ImageMetadata.strip(MediaFixtures.path("gps.png"), dest, ".png")

    assert MediaFixtures.image_metadata_fields(File.read!(dest)) == []
    stored = File.read!(dest)
    refute stored =~ "secret comment"
    refute stored =~ "Someone"
  end

  for name <- ~w(animated.gif animated.webp) do
    @tag :tmp_dir
    test "keeps every frame of #{name} and drops its metadata", %{tmp_dir: tmp_dir} do
      name = unquote(name)
      dest = Path.join(tmp_dir, name)

      assert :ok = ImageMetadata.strip(MediaFixtures.path(name), dest, Path.extname(name))

      {:ok, image} = VipsImage.new_from_buffer(File.read!(dest), n: -1)
      assert {:ok, 3} = VipsImage.header_value(image, "n-pages")
      assert {:ok, 8} = VipsImage.header_value(image, "page-height")
      stored = File.read!(dest)
      refute stored =~ "secret comment"
      refute stored =~ "Someone"
    end
  end

  @tag :tmp_dir
  test "keeps the ICC colour profile", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "p3.jpg")
    dest = Path.join(tmp_dir, "stored.jpg")
    {:ok, red} = Image.new(4, 4, color: :red)
    Image.write!(red, source, icc_profile: :p3)

    assert :ok = ImageMetadata.strip(source, dest, ".jpg")

    {:ok, stored} = VipsImage.new_from_buffer(File.read!(dest))
    assert {:ok, profile} = VipsImage.header_value(stored, "icc-profile-data")
    assert byte_size(profile) > 0
  end

  @tag :tmp_dir
  test "rewrites the file in place when source and destination are the same", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "upload")
    File.cp!(MediaFixtures.path("gps.webp"), path)

    assert :ok = ImageMetadata.strip(path, path, ".webp")

    assert MediaFixtures.image_metadata_fields(File.read!(path)) == []
    assert File.ls!(tmp_dir) == ["upload"]
  end

  @tag :tmp_dir
  test "encodes in the format the extension names", %{tmp_dir: tmp_dir} do
    dest = Path.join(tmp_dir, "avatar.png")

    assert :ok = ImageMetadata.strip(MediaFixtures.path("gps_portrait.jpg"), dest, ".PNG")

    assert <<0x89, "PNG", _rest::binary>> = File.read!(dest)
  end

  @tag :tmp_dir
  test "refuses a file that only looks like an image", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "fake.gif")
    dest = Path.join(tmp_dir, "stored.gif")
    File.write!(source, "GIF89a" <> "not really an image")

    assert {:error, :invalid_image_format} = ImageMetadata.strip(source, dest, ".gif")
    refute File.exists?(dest)
  end

  @tag :tmp_dir
  test "refuses an image whose declared canvas would exhaust memory", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "bomb.png")
    dest = Path.join(tmp_dir, "stored.png")
    File.write!(source, png_declaring(20_000, 20_000))

    assert {:error, :image_too_large} = ImageMetadata.strip(source, dest, ".png")
    refute File.exists?(dest)
  end

  @tag :tmp_dir
  test "refuses an extension no encoder handles", %{tmp_dir: tmp_dir} do
    dest = Path.join(tmp_dir, "stored.txt")

    assert {:error, :invalid_image_format} =
             ImageMetadata.strip(MediaFixtures.path("gps.webp"), dest, ".txt")

    assert File.ls!(tmp_dir) == []
  end

  describe "metadata?/1" do
    @tag :tmp_dir
    test "is true for a file carrying metadata and false once stripped", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "avatar.jpg")
      File.cp!(MediaFixtures.path("gps_portrait.jpg"), path)

      assert {:ok, true} = ImageMetadata.metadata?(path)
      :ok = ImageMetadata.strip(path, path, ".jpg")
      assert {:ok, false} = ImageMetadata.metadata?(path)
    end

    @tag :tmp_dir
    test "is false for an image with nothing to remove", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "clean.png")
      File.write!(path, MediaFixtures.png())

      assert {:ok, false} = ImageMetadata.metadata?(path)
    end

    @tag :tmp_dir
    test "reports a file that is not an image", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "fake.jpg")
      File.write!(path, "not an image")

      assert {:error, :invalid_image_format} = ImageMetadata.metadata?(path)
    end
  end

  # A well-formed PNG declaring a `width` x `height` RGB canvas, with no pixel
  # data behind it: enough for a decoder to read the size.
  defp png_declaring(width, height) do
    ihdr = <<width::32, height::32, 8, 2, 0, 0, 0>>

    <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <>
      chunk("IHDR", ihdr) <>
      chunk("IDAT", :zlib.compress(<<>>)) <> chunk("IEND", <<>>)
  end

  defp chunk(type, data),
    do: <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
end
