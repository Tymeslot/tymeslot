defmodule TymeslotWeb.Helpers.ImageUploadErrorsTest do
  use ExUnit.Case, async: true

  @moduletag :utils

  alias TymeslotWeb.Helpers.ImageUploadErrors

  describe "message/1" do
    test "names the image's size and the limit it is over" do
      assert ImageUploadErrors.message(
               {:image_too_large, %{pixels: 16_810_000, max_pixels: 16_000_000}}
             ) ==
               "This image is too large (16.9 megapixels). " <>
                 "Please upload an image of at most 16 megapixels."
    end

    test "rounds the size up, so an image just over the limit never reads as at it" do
      assert ImageUploadErrors.message(
               {:image_too_large, %{pixels: 40_000_001, max_pixels: 40_000_000}}
             ) =~ "(40.1 megapixels)"
    end

    test "formats the numbers for the current locale" do
      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        assert ImageUploadErrors.message(
                 {:image_too_large, %{pixels: 40_008_000, max_pixels: 40_000_000}}
               ) =~ "40,1"
      end)
    end

    test "asks the user to retry when other uploads are being processed" do
      assert ImageUploadErrors.message(:busy) ==
               "We are busy processing other uploads. Please try again in a moment."
    end

    test "words an avatar's refusals" do
      assert ImageUploadErrors.message(:invalid_file_type) ==
               "This file type is not accepted. Please upload a JPG, PNG, GIF or WebP image."

      assert ImageUploadErrors.message({:file_too_large, 10}) ==
               "This file is too large. Please upload a file of at most 10 MB."

      assert ImageUploadErrors.message(:invalid_image_format) ==
               "This file is not an image we can read. Please upload a different image."

      assert ImageUploadErrors.message(:unreadable_file) ==
               "The file could not be read. Please upload it again."
    end

    test "leaves other reasons to the caller's own message" do
      assert ImageUploadErrors.message(:enospc) == nil
      assert ImageUploadErrors.message({:error, :eacces}) == nil
    end
  end
end
