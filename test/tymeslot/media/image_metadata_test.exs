defmodule Tymeslot.Media.ImageMetadataTest do
  use ExUnit.Case, async: true

  @moduletag :security
  @moduletag :unit

  alias Tymeslot.Integrations.Shared.Lock
  alias Tymeslot.Media.ImageMetadata
  alias Tymeslot.Test.MediaFixtures
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  # The JPEG standard's (Annex K) luminance quantisation table, which
  # libjpeg scales by the quality setting.
  @annex_k_luminance [
    16,
    11,
    10,
    16,
    24,
    40,
    51,
    61,
    12,
    12,
    14,
    19,
    26,
    58,
    60,
    55,
    14,
    13,
    16,
    24,
    40,
    57,
    69,
    56,
    14,
    17,
    22,
    29,
    51,
    87,
    80,
    62,
    18,
    22,
    37,
    56,
    68,
    109,
    103,
    77,
    24,
    35,
    55,
    64,
    81,
    104,
    113,
    92,
    49,
    64,
    78,
    87,
    103,
    121,
    120,
    101,
    72,
    92,
    95,
    98,
    112,
    100,
    103,
    99
  ]

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

  describe "keeping the upload's quality" do
    @tag :tmp_dir
    test "writes a JPEG at quality 90 rather than the encoder's default 75", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "photo.jpg")
      dest = Path.join(tmp_dir, "stored.jpg")
      :ok = VipsImage.write_to_file(noise(64, 64), source <> "[Q=95]")

      assert :ok = ImageMetadata.strip(source, dest, ".jpg")

      assert Enum.sort(luminance_table(File.read!(dest))) == Enum.sort(scaled_luminance(90))
    end

    @tag :tmp_dir
    test "re-encodes a lossy WebP closer to the original than the default quality would",
         %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "photo.webp")
      dest = Path.join(tmp_dir, "stored.webp")
      {:ok, original} = VipsImage.write_to_buffer(noise(64, 64), ".webp", Q: 95)
      File.write!(source, original)
      {:ok, at_default} = VipsImage.write_to_buffer(decode(original), ".webp")

      assert :ok = ImageMetadata.strip(source, dest, ".webp")

      stored = File.read!(dest)
      assert lossy_webp?(stored)
      assert mean_difference(stored, original) < mean_difference(at_default, original)
    end

    @tag :tmp_dir
    test "keeps a lossless WebP lossless, pixel for pixel", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "graphic.webp")
      dest = Path.join(tmp_dir, "stored.webp")
      {:ok, original} = VipsImage.write_to_buffer(noise(64, 64), ".webp", lossless: true)
      File.write!(source, original)

      assert :ok = ImageMetadata.strip(source, dest, ".webp")

      stored = File.read!(dest)
      refute lossy_webp?(stored)
      assert max_difference(stored, original) == 0.0
    end

    @tag :tmp_dir
    test "keeps every frame of a lossless animated WebP lossless", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "animated.webp")
      dest = Path.join(tmp_dir, "stored.webp")
      {:ok, frames} = VipsImage.new_from_buffer(MediaFixtures.read!("animated.webp"), n: -1)
      {:ok, original} = VipsImage.write_to_buffer(frames, ".webp", lossless: true)
      File.write!(source, original)

      assert :ok = ImageMetadata.strip(source, dest, ".webp")

      stored = File.read!(dest)
      assert stored =~ "ANMF"
      refute lossy_webp?(stored)
    end

    @tag :tmp_dir
    test "keeps a palette PNG a palette PNG, pixel for pixel", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "logo.png")
      dest = Path.join(tmp_dir, "stored.png")
      {:ok, original} = VipsImage.write_to_buffer(noise(64, 64), ".png", palette: true)
      File.write!(source, original)
      assert png_colour_type(original) == :palette

      assert :ok = ImageMetadata.strip(source, dest, ".png")

      stored = File.read!(dest)
      assert png_colour_type(stored) == :palette
      assert max_difference(stored, original) == 0.0
    end

    @tag :tmp_dir
    test "keeps a truecolour PNG truecolour", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "photo.png")
      dest = Path.join(tmp_dir, "stored.png")
      :ok = VipsImage.write_to_file(noise(64, 64), source)

      assert :ok = ImageMetadata.strip(source, dest, ".png")

      stored = File.read!(dest)
      assert png_colour_type(stored) == :truecolour
      assert max_difference(stored, File.read!(source)) == 0.0
    end

    @tag :tmp_dir
    test "keeps the colours of a GIF exactly", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "photo.gif")
      dest = Path.join(tmp_dir, "stored.gif")
      :ok = VipsImage.write_to_file(noise(64, 64), source)

      assert :ok = ImageMetadata.strip(source, dest, ".gif")

      assert max_difference(File.read!(dest), File.read!(source)) == 0.0
    end
  end

  describe "bounding memory" do
    @tag :tmp_dir
    test "refuses any image above 40 megapixels", %{tmp_dir: tmp_dir} do
      source = Path.join(tmp_dir, "large.png")
      File.write!(source, png_declaring(8000, 5001))

      assert {:error, :image_too_large} =
               ImageMetadata.strip(source, Path.join(tmp_dir, "stored.png"), ".png")
    end

    @tag :tmp_dir
    test "refuses a WebP above 16 megapixels that another format could store",
         %{tmp_dir: tmp_dir} do
      # 4100 x 4100 is 16.8 megapixels: over the WebP bound, under the general one.
      {:ok, black} = Operation.black(4100, 4100, bands: 3)
      webp = Path.join(tmp_dir, "large.webp")
      png = Path.join(tmp_dir, "large.png")
      :ok = VipsImage.write_to_file(black, webp)
      :ok = VipsImage.write_to_file(black, png)

      assert {:error, :image_too_large} =
               ImageMetadata.strip(webp, Path.join(tmp_dir, "stored.webp"), ".webp")

      assert {:error, :image_too_large} =
               ImageMetadata.strip(png, Path.join(tmp_dir, "stored.webp"), ".webp")

      assert :ok = ImageMetadata.strip(png, Path.join(tmp_dir, "stored.png"), ".png")
    end

    @tag :tmp_dir
    test "waits for a strip already running on this node", %{tmp_dir: tmp_dir} do
      source = MediaFixtures.path("gps.png")
      dest = Path.join(tmp_dir, "stored.png")
      test_pid = self()

      Lock.with_lock(
        {:image_metadata, :strip},
        fn ->
          Task.start(fn ->
            send(test_pid, {:stripped, ImageMetadata.strip(source, dest, ".png")})
          end)

          refute_receive {:stripped, _result}, 500
          refute File.exists?(dest)
        end,
        mode: :blocking
      )

      assert_receive {:stripped, :ok}, 5_000
      assert File.exists?(dest)
    end
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

  # Deterministic three-band noise: hard to compress, so any loss of quality
  # in an encoder shows in the decoded pixels.
  defp noise(width, height) do
    bands =
      for seed <- 1..3 do
        {:ok, band} = Operation.gaussnoise(width, height, sigma: 40.0, seed: seed)
        band
      end

    {:ok, joined} = Operation.bandjoin(bands)
    {:ok, pixels} = Operation.cast(joined, :VIPS_FORMAT_UCHAR)
    {:ok, image} = Operation.copy(pixels, interpretation: :VIPS_INTERPRETATION_sRGB)
    image
  end

  defp decode(contents) do
    {:ok, image} = VipsImage.new_from_buffer(contents, n: -1)
    image
  end

  defp max_difference(a, b) do
    {:ok, {max, _position}} = a |> absolute_difference(b) |> Operation.max()
    max
  end

  defp mean_difference(a, b) do
    {:ok, mean} = a |> absolute_difference(b) |> Operation.avg()
    mean
  end

  defp absolute_difference(a, b) do
    {:ok, difference} = Operation.subtract(decode(a), decode(b))
    {:ok, absolute} = Operation.abs(difference)
    absolute
  end

  # Lossy WebP image data is held in `VP8 ` chunks, lossless in `VP8L`.
  defp lossy_webp?(<<"RIFF", _size::binary-4, "WEBP", _chunks::binary>> = contents),
    do: contents =~ "VP8 "

  # The first quantisation table of a JPEG, which for a colour image is the
  # luminance one, found by walking the segments before the image data.
  defp luminance_table(<<0xFF, 0xD8, segments::binary>>), do: find_dqt(segments)

  defp find_dqt(<<0xFF, 0xDB, _length::16, 0, table::binary-64, _rest::binary>>),
    do: :binary.bin_to_list(table)

  defp find_dqt(<<0xFF, _marker, length::16, rest::binary>>),
    do: find_dqt(binary_part(rest, length - 2, byte_size(rest) - length + 2))

  # libjpeg's scaling of the standard table for a quality of 50 or more.
  defp scaled_luminance(quality) do
    scale = 200 - 2 * quality
    Enum.map(@annex_k_luminance, &(div(&1 * scale + 50, 100) |> max(1) |> min(255)))
  end

  defp png_colour_type(
         <<_signature::binary-8, _length::32, "IHDR", _size::binary-8, _depth, colour_type,
           _rest::binary>>
       ) do
    case colour_type do
      3 -> :palette
      type when type in [2, 6] -> :truecolour
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
