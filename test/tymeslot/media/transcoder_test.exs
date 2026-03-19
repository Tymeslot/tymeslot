defmodule Tymeslot.Media.TranscoderTest do
  use ExUnit.Case, async: true

  @moduletag :workers

  alias Tymeslot.Media.Transcoder

  describe "available?/0" do
    test "returns true when ffmpeg is installed" do
      assert Transcoder.available?()
    end
  end

  describe "variant_definitions/0" do
    test "returns all four variant definitions" do
      variants = Transcoder.variant_definitions()
      assert length(variants) == 4

      suffixes = Enum.map(variants, & &1.suffix)
      assert "-desktop.webm" in suffixes
      assert "-desktop.mp4" in suffixes
      assert "-mobile.mp4" in suffixes
      assert "-low.mp4" in suffixes
    end
  end

  describe "derive_variant_paths/1" do
    test "derives variant paths from original upload path" do
      paths = Transcoder.derive_variant_paths("/uploads/videos/abc123.mp4")

      assert paths == [
               "/uploads/videos/abc123-desktop.webm",
               "/uploads/videos/abc123-desktop.mp4",
               "/uploads/videos/abc123-mobile.mp4",
               "/uploads/videos/abc123-low.mp4"
             ]
    end

    test "handles filenames with multiple dots" do
      paths = Transcoder.derive_variant_paths("/uploads/videos/my.file.name.mp4")

      assert paths == [
               "/uploads/videos/my.file.name-desktop.webm",
               "/uploads/videos/my.file.name-desktop.mp4",
               "/uploads/videos/my.file.name-mobile.mp4",
               "/uploads/videos/my.file.name-low.mp4"
             ]
    end
  end
end
