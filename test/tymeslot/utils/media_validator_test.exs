defmodule Tymeslot.Utils.MediaValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :utils

  alias Tymeslot.Utils.MediaValidator

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

    test "returns false for invalid video" do
      refute MediaValidator.valid_video?(<<"not a video">>)
    end

    test "returns false for empty binary" do
      refute MediaValidator.valid_video?(<<>>)
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
end
