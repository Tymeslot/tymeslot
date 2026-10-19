defmodule Tymeslot.Media.MediaValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :utils

  alias Tymeslot.Media.MediaValidator
  alias Tymeslot.Test.MediaFixtures

  describe "valid_image?/1" do
    test "returns true for valid PNG" do
      png_header = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
      # ExImageInfo needs enough bytes to identify
      assert MediaValidator.valid_image?(
               png_header <>
                 <<0, 0, 0, 13, "IHDR", 0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, 0x90, 0x77, 0x53,
                   0xDE>>
             )
    end

    test "returns false for invalid image" do
      refute MediaValidator.valid_image?(<<"not an image">>)
    end

    test "returns false for empty binary" do
      refute MediaValidator.valid_image?(<<>>)
    end
  end

  describe "valid_video?/1" do
    test "returns true for MP4" do
      assert MediaValidator.valid_video?(<<0, 0, 0, 20, "ftypmp42">>)
    end

    test "returns true for WebM" do
      assert MediaValidator.valid_video?(<<0x1A, 0x45, 0xDF, 0xA3, 0x01>>)
    end

    test "returns true for QuickTime MOV" do
      assert MediaValidator.valid_video?(<<0, 0, 0, 20, "ftypqt  ", 0, 0, 2, 0>>)
    end

    test "returns true for an ISO base media MP4" do
      assert MediaValidator.valid_video?(<<0, 0, 0, 24, "ftypisom", 0, 0, 2, 0>>)
    end

    test "accepts every video brand of the ISO base media family" do
      brands =
        ~w(isom iso2 iso3 iso4 iso5 iso6 iso7 iso8 iso9 mp41 mp42 avc1 cmfc dash) ++
          ~w(3gp4 3gp5 3gp6 3g2a 3g2b 3g2c) ++ ["qt  ", "M4V ", "M4VH", "M4VP"]

      assert Enum.reject(brands, &MediaValidator.valid_video?(ftyp(&1, [&1]))) == []
    end

    test "accepts a camera's own brand that lists a video brand as compatible" do
      # Sony cameras write these, with MP4 brands after them.
      assert MediaValidator.valid_video?(ftyp("XAVC", ["XAVC", "mp42", "iso2"]))
      assert MediaValidator.valid_video?(ftyp("MSNV", ["MSNV", "mp42", "isom"]))
    end

    test "refuses an unknown brand with no video brand among its compatible brands" do
      refute MediaValidator.valid_video?(ftyp("abcd", ["abcd", "wxyz"]))
    end

    test "refuses still images and audio of the same family renamed as video" do
      # HEIC, AVIF and M4A all start with an ftyp box, and routinely list MP4
      # brands as compatible, which alone once passed.
      for brand <- ["heic", "mif1", "avif", "M4A "] do
        refute MediaValidator.valid_video?(ftyp(brand, [brand, "mp42", "isom"])),
               "brand #{inspect(brand)} passed"
      end
    end

    test "reads compatible brands only within the ftyp box" do
      # A video brand in the bytes after a box that lists none is not one of
      # its brands.
      refute MediaValidator.valid_video?(ftyp("abcd", ["abcd"]) <> "isom")
    end

    test "refuses a GIF, although its first byte is the MPEG-TS sync byte" do
      # "G" is 0x47. A GIF named `.mp4` used to pass as an MPEG transport
      # stream, and was stored and queued for transcoding.
      refute MediaValidator.valid_video?("GIF89a" <> :binary.copy(<<0>>, 32))
      refute MediaValidator.valid_video?("GIF87a" <> :binary.copy(<<0>>, 32))
    end

    test "refuses containers the upload allowlist never admits" do
      # MPEG-TS (sync byte every 188 bytes), MPEG-PS, FLV and AVI.
      ts_packet = <<0x47>> <> :binary.copy(<<0xFF>>, 187)
      refute MediaValidator.valid_video?(:binary.copy(ts_packet, 3))
      refute MediaValidator.valid_video?(<<0x00, 0x00, 0x01, 0xBA, 0x44, 0x00>>)
      refute MediaValidator.valid_video?(<<"FLV", 0x01, 0x05, 0, 0, 0, 9>>)
      refute MediaValidator.valid_video?(<<"RIFF", 0, 0, 0, 0, "AVI LIST">>)
    end

    test "returns false for invalid video" do
      refute MediaValidator.valid_video?(<<"not a video">>)
    end

    test "returns false for empty binary" do
      refute MediaValidator.valid_video?(<<>>)
    end
  end

  describe "valid_captions?/1" do
    test "accepts the WebVTT signature, alone, after a byte order mark, or with a header" do
      assert MediaValidator.valid_captions?("WEBVTT")
      assert MediaValidator.valid_captions?("WEBVTT\n\n00:00.000 --> 00:02.000\nHello\n")
      assert MediaValidator.valid_captions?("WEBVTT\r\n\r\n00:00.000 --> 00:02.000\nHello\r\n")
      assert MediaValidator.valid_captions?(<<0xEF, 0xBB, 0xBF>> <> "WEBVTT\n")
      assert MediaValidator.valid_captions?("WEBVTT - Intro clip\n")
      assert MediaValidator.valid_captions?("WEBVTT\tIntro clip\n")
    end

    test "refuses anything else" do
      refute MediaValidator.valid_captions?("WEBVTTX\n")
      refute MediaValidator.valid_captions?("webvtt\n")
      refute MediaValidator.valid_captions?("1\n00:00:01,000 --> 00:00:02,000\nHello\n")
      refute MediaValidator.valid_captions?(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>)
      refute MediaValidator.valid_captions?("")
      refute MediaValidator.valid_captions?(nil)
    end
  end

  describe "valid_image_file?/1, valid_video_file?/1, valid_png_file?/1 file handling" do
    test "returns false for a 0-byte file without leaking the file handle" do
      path =
        Path.join(
          System.tmp_dir!(),
          "media_validator_empty_#{System.unique_integer([:positive])}"
        )

      File.write!(path, "")
      on_exit(fn -> File.rm(path) end)

      before_count = open_file_devices()

      for _index <- 1..50 do
        refute MediaValidator.valid_image_file?(path)
        refute MediaValidator.valid_video_file?(path)
        refute MediaValidator.valid_png_file?(path)
      end

      # 150 calls, so a handle leaked once per call is 150 devices. The slack
      # covers a file another async test holds open across this assertion,
      # which is the only thing besides a leak that moves this count.
      assert open_file_devices() - before_count <= 5
    end

    test "returns false for a directory path" do
      dir = System.tmp_dir!()

      refute MediaValidator.valid_image_file?(dir)
      refute MediaValidator.valid_video_file?(dir)
      refute MediaValidator.valid_png_file?(dir)
    end

    test "returns false for a nonexistent path" do
      path =
        Path.join(
          System.tmp_dir!(),
          "media_validator_missing_#{System.unique_integer([:positive])}"
        )

      refute MediaValidator.valid_image_file?(path)
      refute MediaValidator.valid_video_file?(path)
      refute MediaValidator.valid_png_file?(path)
    end

    # A phone photo's EXIF block, with its embedded thumbnail, comes before
    # the JPEG's own SOF marker, so its dimensions are not in the first
    # kilobytes of the file.
    test "returns true for a JPEG whose EXIF block is larger than its header" do
      assert MediaValidator.valid_image_file?(MediaFixtures.path("exif_thumbnail.jpg"))
    end

    test "returns true for a valid PNG file" do
      path =
        Path.join(System.tmp_dir!(), "media_validator_png_#{System.unique_integer([:positive])}")

      png =
        <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 0, 0, 0, 1, 0, 0,
          0, 1, 8, 2, 0, 0, 0, 0x90, 0x77, 0x53, 0xDE>>

      File.write!(path, png)
      on_exit(fn -> File.rm(path) end)

      assert MediaValidator.valid_image_file?(path)
      assert MediaValidator.valid_png_file?(path)
      refute MediaValidator.valid_video_file?(path)
    end
  end

  # Counts the processes a leaked handle would leave behind, and nothing else:
  # `File.open/2` without `:raw` spawns a device that sits in
  # `:file_io_server.server_loop/1` until it is closed.
  #
  # Counting these rather than `Process.list/0` is what makes the assertion
  # above mean anything. The node's total process count moves constantly under
  # async tests — Oban jobs, LiveViews, Ecto checkouts — so a threshold against
  # it is either too tight to survive an unrelated test running alongside (this
  # one failed at 28 against a limit of 20) or too loose to catch the leak it
  # exists to catch. Restricted to file devices, the count sits near zero, so
  # the leak signal is unmistakable and the noise is not.
  defp open_file_devices do
    Enum.count(Process.list(), fn pid ->
      match?(
        {:current_function, {:file_io_server, _fun, _arity}},
        Process.info(pid, :current_function)
      )
    end)
  end

  # An ftyp box with the given major brand, minor version 0 and the given
  # compatible brands, sized as real files size it.
  defp ftyp(major, compatible) do
    brands = Enum.join(compatible)
    <<16 + byte_size(brands)::32, "ftyp", major::binary, 0::32, brands::binary>>
  end
end
