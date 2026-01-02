defmodule Tymeslot.ThemeCustomizationsDataTransformTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.DatabaseSchemas.ThemeCustomizationSchema
  alias Tymeslot.ThemeCustomizations.DataTransform

  describe "DataTransform module" do
    test "extract_save_attributes/1 from struct" do
      customization = %ThemeCustomizationSchema{
        profile_id: 1,
        theme_id: "1",
        color_scheme: "purple",
        background_type: "gradient",
        background_value: "gradient_1",
        background_image_path: nil,
        background_video_path: nil
      }

      attrs = DataTransform.extract_save_attributes(customization)

      assert attrs["color_scheme"] == "purple"
      assert attrs["background_type"] == "gradient"
      assert attrs["background_value"] == "gradient_1"
    end

    test "extract_save_attributes/1 from map" do
      customization = %{
        color_scheme: "sunset",
        background_type: "color",
        background_value: "#ff5500"
      }

      attrs = DataTransform.extract_save_attributes(customization)

      assert attrs["color_scheme"] == "sunset"
    end

    test "merge_customization_changes/2 with struct" do
      current = %ThemeCustomizationSchema{
        profile_id: 1,
        theme_id: "1",
        color_scheme: "default",
        background_type: "gradient",
        background_value: "gradient_1",
        background_image_path: nil,
        background_video_path: nil
      }

      updated = DataTransform.merge_customization_changes(current, %{color_scheme: "purple"})

      assert updated.color_scheme == "purple"
      assert updated.background_type == "gradient"
    end

    test "merge_customization_changes/2 with map" do
      current = %{color_scheme: "default", background_type: "gradient"}
      updated = DataTransform.merge_customization_changes(current, %{color_scheme: "purple"})

      assert updated.color_scheme == "purple"
    end

    test "normalize_background_value/2 normalizes gradient" do
      assert DataTransform.normalize_background_value("gradient", "gradient_1") == "gradient_1"
      assert DataTransform.normalize_background_value(:gradient, "gradient_1") == "gradient_1"
    end

    test "normalize_background_value/2 normalizes color to lowercase" do
      assert DataTransform.normalize_background_value("color", "#FF5500") == "#ff5500"
    end

    test "normalize_background_value/2 handles custom values" do
      assert DataTransform.normalize_background_value("image", "custom") == "custom"
      assert DataTransform.normalize_background_value("video", "custom") == "custom"
    end

    test "build_customization_from_assigns/2 creates struct" do
      assigns = %{
        profile: %{id: 1},
        color_scheme: "purple",
        background_type: "gradient",
        background_value: "gradient_2"
      }

      customization = DataTransform.build_customization_from_assigns(assigns, "1")

      assert customization.profile_id == 1
      assert customization.theme_id == "1"
      assert customization.color_scheme == "purple"
    end

    test "build_customization_from_assigns/2 uses defaults for missing values" do
      assigns = %{profile: %{id: 1}}
      customization = DataTransform.build_customization_from_assigns(assigns, "1")

      assert customization.color_scheme == "default"
      assert customization.background_type == "gradient"
    end

    test "convert_to_map/1 converts struct to map" do
      customization = %ThemeCustomizationSchema{
        color_scheme: "purple",
        background_type: "gradient",
        background_value: "gradient_1"
      }

      map = DataTransform.convert_to_map(customization)

      assert map["color_scheme"] == "purple"
    end

    test "convert_to_map/1 handles nil" do
      assert DataTransform.convert_to_map(nil) == %{}
    end

    test "convert_to_map/1 converts atom keys to strings" do
      map = DataTransform.convert_to_map(%{color_scheme: "purple"})

      assert map["color_scheme"] == "purple"
    end

    test "atomize_keys/1 converts string keys to atoms" do
      input = %{"color_scheme" => "purple", "background_type" => "gradient"}
      result = DataTransform.atomize_keys(input)

      assert result[:color_scheme] == "purple"
      assert result[:background_type] == "gradient"
    end

    test "prepare_upload_attributes/3 for image upload" do
      current = %ThemeCustomizationSchema{
        profile_id: 1,
        theme_id: "1",
        color_scheme: "default",
        background_type: "gradient",
        background_value: "gradient_1",
        background_image_path: nil,
        background_video_path: nil
      }

      result = DataTransform.prepare_upload_attributes(current, :image, "themes/1/images/bg.jpg")

      assert result.background_type == "image"
      assert result.background_value == "custom"
      assert result.background_image_path == "themes/1/images/bg.jpg"
      assert result.background_video_path == nil
    end

    test "prepare_upload_attributes/3 for video upload" do
      current = %ThemeCustomizationSchema{
        profile_id: 1,
        theme_id: "1",
        color_scheme: "default",
        background_type: "gradient",
        background_value: "gradient_1",
        background_image_path: nil,
        background_video_path: nil
      }

      result = DataTransform.prepare_upload_attributes(current, :video, "themes/1/videos/bg.mp4")

      assert result.background_type == "video"
      assert result.background_value == "custom"
      assert result.background_video_path == "themes/1/videos/bg.mp4"
      assert result.background_image_path == nil
    end

    test "create_customization_diff/2 identifies changes" do
      old = %ThemeCustomizationSchema{
        profile_id: 1,
        theme_id: "1",
        color_scheme: "default",
        background_type: "gradient",
        background_value: "gradient_1",
        background_image_path: nil,
        background_video_path: nil
      }

      new = %ThemeCustomizationSchema{
        profile_id: 1,
        theme_id: "1",
        color_scheme: "purple",
        background_type: "gradient",
        background_value: "gradient_2",
        background_image_path: nil,
        background_video_path: nil
      }

      diff = DataTransform.create_customization_diff(old, new)

      assert diff["color_scheme"] == %{from: "default", to: "purple"}
      assert diff["background_value"] == %{from: "gradient_1", to: "gradient_2"}
      refute Map.has_key?(diff, "background_type")
    end

    test "clean_customization_attributes/1 removes empty strings" do
      attrs = %{
        "color_scheme" => "purple",
        "background_type" => "  ",
        "background_value" => nil
      }

      cleaned = DataTransform.clean_customization_attributes(attrs)

      assert cleaned["color_scheme"] == "purple"
      refute Map.has_key?(cleaned, "background_type")
    end

    test "has_background_files?/1 detects image path" do
      with_image = %ThemeCustomizationSchema{background_image_path: "path/to/image.jpg"}
      without = %ThemeCustomizationSchema{background_image_path: nil, background_video_path: nil}

      assert DataTransform.has_background_files?(with_image) == true
      assert DataTransform.has_background_files?(without) == false
    end

    test "has_background_files?/1 detects video path" do
      with_video = %ThemeCustomizationSchema{background_video_path: "path/to/video.mp4"}

      assert DataTransform.has_background_files?(with_video) == true
    end

    test "get_active_background_file/1 returns custom image path" do
      customization = %ThemeCustomizationSchema{
        background_type: "image",
        background_value: "custom",
        background_image_path: "themes/1/images/bg.jpg"
      }

      assert DataTransform.get_active_background_file(customization) == "themes/1/images/bg.jpg"
    end

    test "get_active_background_file/1 returns custom video path" do
      customization = %ThemeCustomizationSchema{
        background_type: "video",
        background_value: "custom",
        background_video_path: "themes/1/videos/bg.mp4"
      }

      assert DataTransform.get_active_background_file(customization) == "themes/1/videos/bg.mp4"
    end

    test "get_active_background_file/1 returns nil for preset backgrounds" do
      customization = %ThemeCustomizationSchema{
        background_type: "video",
        background_value: "preset:rhythm-default",
        background_video_path: nil
      }

      assert DataTransform.get_active_background_file(customization) == nil
    end
  end
end
