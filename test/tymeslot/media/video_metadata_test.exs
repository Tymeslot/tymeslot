defmodule Tymeslot.Media.VideoMetadataTest do
  use ExUnit.Case, async: true

  @moduletag :security
  @moduletag :unit

  alias Tymeslot.Media.MediaValidator
  alias Tymeslot.Media.VideoMetadata
  alias Tymeslot.Test.MediaFixtures

  describe "MP4" do
    test "removes the location, title and device details a phone records" do
      path = MediaFixtures.temp_copy!("gps.mp4")
      original = File.read!(path)

      for marker <- [<<0xA9, "xyz">>, "loci", "location.ISO6709", "Kitchen", "Model-X"] do
        assert original =~ marker
      end

      assert {:ok, :stripped} = VideoMetadata.strip(path)

      stripped = File.read!(path)

      for marker <- [<<0xA9, "xyz">>, "loci", "location.ISO6709", "Kitchen", "Model-X"] do
        refute stripped =~ marker
      end
    end

    test "zeroes the creation and modification times of the movie, track and media" do
      path = MediaFixtures.temp_copy!("gps.mp4")
      assert Enum.all?(header_times(File.read!(path)), &(&1 != 0))

      assert {:ok, :stripped} = VideoMetadata.strip(path)

      times = header_times(File.read!(path))
      assert length(times) == 6
      assert Enum.reject(times, &(&1 == 0)) == []
    end

    test "leaves the file the same size, with the media data untouched" do
      path = MediaFixtures.temp_copy!("gps.mp4")
      original = File.read!(path)

      assert {:ok, :stripped} = VideoMetadata.strip(path)

      stripped = File.read!(path)
      assert byte_size(stripped) == byte_size(original)
      assert box(stripped, "mdat") == box(original, "mdat")
      assert box(stripped, "stco") == box(original, "stco")
    end

    test "a second pass finds nothing left to remove and writes nothing" do
      path = MediaFixtures.temp_copy!("gps.mp4")
      assert {:ok, :stripped} = VideoMetadata.strip(path)
      once = File.read!(path)

      assert {:ok, :unchanged} = VideoMetadata.strip(path)
      assert File.read!(path) == once
    end

    @tag :tmp_dir
    test "handles a box with a 64-bit size", %{tmp_dir: tmp_dir} do
      udta = <<1::32, "udta", 16 + 8::64, "SECRET!!">>
      path = write!(tmp_dir, "large.mp4", mp4([mp4_box("moov", udta)]))

      assert {:ok, :stripped} = VideoMetadata.strip(path)

      stripped = File.read!(path)
      refute stripped =~ "SECRET"
      assert stripped =~ <<1::32, "free", 24::64>>
    end

    @tag :tmp_dir
    test "handles a final box whose size runs to the end of the file", %{tmp_dir: tmp_dir} do
      path = write!(tmp_dir, "open.mp4", mp4([<<0::32, "udta", "SECRET">>]))

      assert {:ok, :stripped} = VideoMetadata.strip(path)
      refute File.read!(path) =~ "SECRET"
    end

    @tag :tmp_dir
    test "refuses a file whose boxes overrun it, and leaves it untouched", %{tmp_dir: tmp_dir} do
      contents = mp4([<<100::32, "udta", "SECRET">>])
      path = write!(tmp_dir, "truncated.mp4", contents)

      assert {:error, :malformed} = VideoMetadata.strip(path)
      assert File.read!(path) == contents
    end
  end

  # QuickTime (`qt  ` brand) is the same box structure. An iPhone writes its
  # location twice: `©xyz` in the movie's user data, and the keyed
  # `com.apple.quicktime.location.ISO6709` in the movie's `meta`.
  describe "QuickTime" do
    @tag :tmp_dir
    test "removes the user-data and keyed location an iPhone records", %{tmp_dir: tmp_dir} do
      location = "+51.5074-000.1278+011.000/"
      key = "com.apple.quicktime.location.ISO6709"

      udta =
        mp4_box(
          "udta",
          mp4_box(<<0xA9, "xyz">>, <<byte_size(location)::16, 0::16, location::binary>>)
        )

      keys = mp4_box("keys", <<0::32, 1::32, 8 + byte_size(key)::32, "mdta", key::binary>>)

      ilst =
        mp4_box("ilst", mp4_box(<<1::32>>, mp4_box("data", <<1::32, 0::32, location::binary>>)))

      meta = mp4_box("meta", mp4_box("hdlr", <<0::64, "mdta", 0::96, 0>>) <> keys <> ilst)

      trak = mp4_box("trak", mp4_box("udta", mp4_box(<<0xA9, "mak">>, "Apple iPhone")))
      mdat = mp4_box("mdat", "FRAMES")

      contents =
        IO.iodata_to_binary([
          mp4_box("ftyp", "qt  " <> <<0::32>> <> "qt  "),
          mp4_box("moov", udta <> meta <> trak),
          mdat
        ])

      path = write!(tmp_dir, "iphone.mov", contents)

      assert MediaValidator.valid_video?(contents)
      assert VideoMetadata.extension(path) == {:ok, ".mp4"}
      assert {:ok, :stripped} = VideoMetadata.strip(path)

      stripped = File.read!(path)

      for marker <- [location, key, <<0xA9, "xyz">>, "Apple iPhone"] do
        refute stripped =~ marker, "#{inspect(marker)} survived"
      end

      assert byte_size(stripped) == byte_size(contents)
      assert stripped =~ mdat
    end
  end

  describe "WebM" do
    test "removes the location, title, device and date tags" do
      path = MediaFixtures.temp_copy!("gps.webm")
      original = File.read!(path)

      for marker <- ["51.5007", "Kitchen", "TestPhone", <<0x44, 0x61>>] do
        assert original =~ marker
      end

      assert {:ok, :stripped} = VideoMetadata.strip(path)

      stripped = File.read!(path)
      assert byte_size(stripped) == byte_size(original)

      for marker <- ["51.5007", "Kitchen", "TestPhone"] do
        refute stripped =~ marker
      end

      assert {:ok, :unchanged} = VideoMetadata.strip(path)
    end

    @tag :tmp_dir
    test "walks a recording whose segment and clusters have no size, as MediaRecorder writes",
         %{tmp_dir: tmp_dir} do
      cluster = ebml_unknown(0x1F43B675, ebml(0xE7, <<0>>) <> ebml(0xA3, "frame"))
      tags = ebml(0x1254C367, ebml(0x7373, "SECRET location"))
      segment = ebml_unknown(0x18538067, cluster <> cluster <> tags)
      contents = ebml(0x1A45DFA3, ebml(0x4282, "webm")) <> segment
      path = write!(tmp_dir, "recording.webm", contents)

      assert {:ok, :stripped} = VideoMetadata.strip(path)

      stripped = File.read!(path)
      refute stripped =~ "SECRET"
      assert byte_size(stripped) == byte_size(contents)
      # The frames before the tags are untouched.
      assert binary_part(stripped, 0, byte_size(contents) - byte_size(tags)) ==
               binary_part(contents, 0, byte_size(contents) - byte_size(tags))

      assert {:ok, :unchanged} = VideoMetadata.strip(path)
    end

    @tag :tmp_dir
    test "voids exactly the bytes of the element it replaces, whatever their length",
         %{tmp_dir: tmp_dir} do
      # A 2-byte Title is the smallest element voided; a 200-byte one needs a
      # two-byte size. Both must leave the next element exactly where it was.
      for title <- ["", String.duplicate("x", 200)] do
        info = ebml(0x1549A966, ebml(0x7BA9, title) <> ebml(0x4D80, "muxer"))
        contents = ebml(0x1A45DFA3, ebml(0x4282, "webm")) <> ebml(0x18538067, info)
        path = write!(tmp_dir, "title.webm", contents)

        assert {:ok, :stripped} = VideoMetadata.strip(path)

        stripped = File.read!(path)
        assert stripped =~ ebml(0x4D80, "muxer")
        assert {:ok, :unchanged} = VideoMetadata.strip(path)
      end
    end

    @tag :tmp_dir
    test "refuses a file whose elements overrun it", %{tmp_dir: tmp_dir} do
      contents = ebml(0x1A45DFA3, ebml(0x4282, "webm")) <> <<0x18, 0x53, 0x80, 0x67, 0x90>>
      path = write!(tmp_dir, "truncated.webm", contents)

      assert {:error, :malformed} = VideoMetadata.strip(path)
      assert File.read!(path) == contents
    end
  end

  @tag :tmp_dir
  test "refuses a container it cannot strip", %{tmp_dir: tmp_dir} do
    contents = "RIFF" <> <<100::little-32>> <> "AVI LIST"
    path = write!(tmp_dir, "clip.avi", contents)

    assert {:error, :unsupported_container} = VideoMetadata.strip(path)
    assert File.read!(path) == contents
  end

  test "reports a file that does not exist" do
    assert {:error, :enoent} = VideoMetadata.strip("/nonexistent/clip.mp4")
  end

  defp write!(dir, name, contents) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end

  defp mp4(boxes), do: IO.iodata_to_binary([mp4_box("ftyp", "isom") | boxes])
  defp mp4_box(type, payload), do: <<8 + byte_size(payload)::32, type::binary, payload::binary>>

  # The creation and modification times of every mvhd, tkhd and mdhd box.
  defp header_times(mp4) do
    for type <- ["mvhd", "tkhd", "mdhd"],
        {position, _length} <- :binary.matches(mp4, type),
        <<0, _flags::24, created::32, modified::32, _rest::binary>> <-
          [binary_part(mp4, position + 4, byte_size(mp4) - position - 4)],
        time <- [created, modified],
        do: time
  end

  defp box(mp4, type) do
    {position, _length} = :binary.match(mp4, type)
    <<size::32>> = binary_part(mp4, position - 4, 4)
    binary_part(mp4, position - 4, size)
  end

  # An element with its size in the fewest bytes, as most muxers write it.
  defp ebml(id, payload) do
    <<:binary.encode_unsigned(id)::binary, ebml_size(byte_size(payload))::binary,
      payload::binary>>
  end

  defp ebml_size(size) when size < 0x7F, do: <<1::1, size::7>>
  defp ebml_size(size) when size < 0x3FFF, do: <<1::2, size::14>>
  defp ebml_size(size), do: <<0x01, size::56>>

  defp ebml_unknown(id, payload),
    do: <<:binary.encode_unsigned(id)::binary, 0x01FFFFFFFFFFFFFF::64, payload::binary>>

  describe "extension/1" do
    test "names MP4 and WebM after their bytes, whatever the file is called" do
      assert VideoMetadata.extension(MediaFixtures.temp_copy!("gps.mp4")) == {:ok, ".mp4"}
      assert VideoMetadata.extension(MediaFixtures.temp_copy!("gps.webm")) == {:ok, ".webm"}
    end

    test "refuses any other container" do
      path = Path.join(System.tmp_dir!(), "avi_#{System.unique_integer([:positive])}.mp4")
      File.write!(path, "RIFF" <> <<100::little-32>> <> "AVI LIST")
      on_exit(fn -> File.rm(path) end)

      assert VideoMetadata.extension(path) == {:error, :unsupported_container}
    end

    test "returns the error for a missing file" do
      assert VideoMetadata.extension("/nonexistent/clip.mp4") == {:error, :enoent}
    end
  end
end
