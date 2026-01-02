defmodule Tymeslot.ThemeCustomizationsBackgroundsTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.DatabaseSchemas.ThemeCustomizationSchema
  alias Tymeslot.ThemeCustomizations.{Backgrounds, Presets}

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

    test "generate_background_description/2 for gradient" do
      presets = Presets.get_all_presets()

      customization = %ThemeCustomizationSchema{
        background_type: "gradient",
        background_value: "gradient_1"
      }

      description = Backgrounds.generate_background_description(customization, presets)

      assert description =~ "Gradient:"
      assert description =~ "Aurora"
    end

    test "generate_background_description/2 for color" do
      customization = %ThemeCustomizationSchema{
        background_type: "color",
        background_value: "#ff5500"
      }

      description = Backgrounds.generate_background_description(customization, %{})

      assert description =~ "Solid Color:"
    end

    test "generate_background_description/2 for custom image" do
      customization = %ThemeCustomizationSchema{
        background_type: "image",
        background_value: "custom",
        background_image_path: "themes/1/images/bg.jpg"
      }

      description = Backgrounds.generate_background_description(customization, %{})

      assert description == "Custom Image Uploaded"
    end

    test "generate_background_description/2 for preset image" do
      presets = Presets.get_all_presets()

      customization = %ThemeCustomizationSchema{
        background_type: "image",
        background_value: "preset:artistic-studio",
        background_image_path: nil
      }

      description = Backgrounds.generate_background_description(customization, presets)

      assert description =~ "Preset:"
    end

    test "generate_background_description/2 for custom video" do
      customization = %ThemeCustomizationSchema{
        background_type: "video",
        background_value: "custom",
        background_video_path: "themes/1/videos/bg.mp4"
      }

      description = Backgrounds.generate_background_description(customization, %{})

      assert description == "Custom Video Uploaded"
    end

    test "generate_background_description/2 for unknown type" do
      customization = %ThemeCustomizationSchema{
        background_type: "unknown",
        background_value: nil
      }

      description = Backgrounds.generate_background_description(customization, %{})

      assert description == "No Background Selected"
    end

    test "get_background_css/2 for gradient" do
      presets = Presets.get_all_presets()

      customization = %ThemeCustomizationSchema{
        background_type: "gradient",
        background_value: "gradient_1"
      }

      css = Backgrounds.get_background_css(customization, presets)

      assert css =~ "linear-gradient"
    end

    test "get_background_css/2 for color" do
      customization = %ThemeCustomizationSchema{
        background_type: "color",
        background_value: "#ff5500"
      }

      assert Backgrounds.get_background_css(customization, %{}) == "#ff5500"
    end

    test "get_background_css/2 for custom image" do
      customization = %ThemeCustomizationSchema{
        background_type: "image",
        background_value: "custom",
        background_image_path: "themes/1/images/bg.jpg"
      }

      css = Backgrounds.get_background_css(customization, %{})

      assert css == "/uploads/themes/1/images/bg.jpg"
    end

    test "get_background_css/2 for custom video" do
      customization = %ThemeCustomizationSchema{
        background_type: "video",
        background_value: "custom",
        background_video_path: "themes/1/videos/bg.mp4"
      }

      css = Backgrounds.get_background_css(customization, %{})

      assert css == "/uploads/themes/1/videos/bg.mp4"
    end

    test "resolve_preview_source/2 for gradient" do
      presets = Presets.get_all_presets()

      customization = %ThemeCustomizationSchema{
        background_type: "gradient",
        background_value: "gradient_1"
      }

      {type, data} = Backgrounds.resolve_preview_source(customization, presets)

      assert type == :gradient
      assert data.css =~ "linear-gradient"
    end

    test "resolve_preview_source/2 for color" do
      customization = %ThemeCustomizationSchema{
        background_type: "color",
        background_value: "#ff5500"
      }

      {type, data} = Backgrounds.resolve_preview_source(customization, %{})

      assert type == :color
      assert data.css == "#ff5500"
    end

    test "resolve_preview_source/2 for custom image" do
      customization = %ThemeCustomizationSchema{
        background_type: "image",
        background_value: "custom",
        background_image_path: "themes/1/images/bg.jpg"
      }

      {type, data} = Backgrounds.resolve_preview_source(customization, %{})

      assert type == :image
      assert data.kind == :custom
      assert data.url == "/uploads/themes/1/images/bg.jpg"
    end

    test "resolve_preview_source/2 for preset video" do
      presets = Presets.get_all_presets()

      customization = %ThemeCustomizationSchema{
        background_type: "video",
        background_value: "preset:rhythm-default",
        background_video_path: nil
      }

      {type, data} = Backgrounds.resolve_preview_source(customization, presets)

      assert type == :video
      assert data.kind == :preset
      assert data.video_url =~ "/videos/backgrounds/"
    end

    test "resolve_preview_source/2 returns :none for invalid" do
      customization = %ThemeCustomizationSchema{
        background_type: "unknown",
        background_value: nil
      }

      assert Backgrounds.resolve_preview_source(customization, %{}) == {:none, %{}}
    end

    test "custom_background?/1 returns true for custom upload" do
      customization = %ThemeCustomizationSchema{
        background_value: "custom",
        background_image_path: "themes/1/images/bg.jpg"
      }

      assert Backgrounds.custom_background?(customization)
    end

    test "custom_background?/1 returns false for preset" do
      customization = %ThemeCustomizationSchema{
        background_value: "preset:rhythm-default",
        background_image_path: nil,
        background_video_path: nil
      }

      refute Backgrounds.custom_background?(customization)
    end

    test "get_background_file_path/2 for custom image" do
      customization = %ThemeCustomizationSchema{
        background_type: "image",
        background_value: "custom",
        background_image_path: "themes/1/images/bg.jpg"
      }

      assert Backgrounds.get_background_file_path(customization, %{}) == "themes/1/images/bg.jpg"
    end

    test "get_background_file_path/2 for preset image" do
      presets = Presets.get_all_presets()

      customization = %ThemeCustomizationSchema{
        background_type: "image",
        background_value: "preset:artistic-studio",
        background_image_path: nil
      }

      path = Backgrounds.get_background_file_path(customization, presets)

      assert path =~ "artistic-studio"
    end
  end
end
