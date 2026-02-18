defmodule Tymeslot.Utils.MediaValidatorTest do
  @moduletag :utils
  use Tymeslot.DataCase, async: true
  alias Tymeslot.Utils.MediaValidator

  describe "valid_image?/1" do
  @moduletag :utils
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

  describe "valid_media?/1" do
    test "returns true for image or video" do
      png_header =
        <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 0, 0, 0, 1, 0, 0,
          0, 1, 8, 2, 0, 0, 0, 0x90, 0x77, 0x53, 0xDE>>

      assert MediaValidator.valid_media?(png_header)
      assert MediaValidator.valid_media?(<<0, 0, 0, 20, "ftypmp42">>)
    end

    test "returns false for others" do
      refute MediaValidator.valid_media?(<<"random data">>)
    end
  end
end
