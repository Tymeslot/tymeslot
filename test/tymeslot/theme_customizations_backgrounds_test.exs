defmodule Tymeslot.ThemeCustomizationsBackgroundsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :utils

  alias Tymeslot.ThemeCustomizations.Backgrounds
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  describe "Backgrounds module" do
    test "apply_background_selection/3 updates type and value" do
      current = %ThemeCustomizationSchema{
        background_type: "gradient",
        background_value: "gradient_1",
        background_image_path: nil,
        background_video_path: nil
      }

      result = Backgrounds.apply_background_selection(current, "color", "#ff5500")

      assert result.background_type == "color"
      assert result.background_value == "#ff5500"
    end

    test "clear_conflicting_backgrounds/2 clears paths for gradient" do
      current = %ThemeCustomizationSchema{
        background_type: "gradient",
        background_value: "gradient_1",
        background_image_path: "old/image.jpg",
        background_video_path: "old/video.mp4"
      }

      result = Backgrounds.clear_conflicting_backgrounds(current, "gradient")

      assert result.background_image_path == nil
      assert result.background_video_path == nil
    end

    test "clear_conflicting_backgrounds/2 clears paths for color" do
      current = %ThemeCustomizationSchema{
        background_type: "color",
        background_value: "#000000",
        background_image_path: "old/image.jpg",
        background_video_path: "old/video.mp4"
      }

      result = Backgrounds.clear_conflicting_backgrounds(current, "color")

      assert result.background_image_path == nil
      assert result.background_video_path == nil
    end

    test "clear_conflicting_backgrounds/2 clears image path for preset image" do
      current = %ThemeCustomizationSchema{
        background_type: "image",
        background_value: "preset:artistic-studio",
        background_image_path: "old/custom.jpg",
        background_video_path: nil
      }

      result = Backgrounds.clear_conflicting_backgrounds(current, "image")

      assert result.background_image_path == nil
    end

    test "clear_conflicting_backgrounds/2 keeps custom image path" do
      current = %ThemeCustomizationSchema{
        background_type: "image",
        background_value: "custom",
        background_image_path: "custom/image.jpg",
        background_video_path: nil
      }

      result = Backgrounds.clear_conflicting_backgrounds(current, "image")

      assert result.background_image_path == "custom/image.jpg"
    end

    test "determine_cleanup_files/2 identifies files to cleanup" do
      old = %ThemeCustomizationSchema{
        background_type: "image",
        background_value: "custom",
        background_image_path: "old/image.jpg",
        background_video_path: nil
      }

      new = %ThemeCustomizationSchema{
        background_type: "gradient",
        background_value: "gradient_1",
        background_image_path: nil,
        background_video_path: nil
      }

      cleanup = Backgrounds.determine_cleanup_files(old, new)

      assert length(cleanup) == 1
      assert %{background_image_path: "old/image.jpg"} in cleanup
    end

    test "determine_cleanup_files/2 returns empty when no cleanup needed" do
      old = %ThemeCustomizationSchema{
        background_type: "gradient",
        background_value: "gradient_1",
        background_image_path: nil,
        background_video_path: nil
      }

      new = %ThemeCustomizationSchema{
        background_type: "gradient",
        background_value: "gradient_2",
        background_image_path: nil,
        background_video_path: nil
      }

      assert Backgrounds.determine_cleanup_files(old, new) == []
    end
  end
end
