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

    test "leaves other reasons to the caller's own message" do
      assert ImageUploadErrors.message(:invalid_image_format) == nil
      assert ImageUploadErrors.message(:enospc) == nil
    end
  end
end
