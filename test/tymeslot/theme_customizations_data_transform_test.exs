defmodule Tymeslot.ThemeCustomizationsDataTransformTest do
  use Tymeslot.DataCase, async: true
  @moduletag :utils

  alias Tymeslot.ThemeCustomizations.DataTransform
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

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
  end
end
