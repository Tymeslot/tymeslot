defmodule Tymeslot.ThemeCustomizationsDefaultsTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.DatabaseSchemas.ThemeCustomizationSchema
  alias Tymeslot.ThemeCustomizations.Defaults

  describe "Defaults module" do
    test "get_theme_defaults/1 returns Quill defaults" do
      defaults = Defaults.get_theme_defaults("1")

      assert defaults.color_scheme == "default"
      assert defaults.background_type == "gradient"
    end

    test "get_theme_defaults/1 returns Rhythm defaults" do
      defaults = Defaults.get_theme_defaults("2")

      assert defaults.color_scheme == "default"
      assert defaults.background_type == "video"
    end

    test "get_theme_defaults/1 returns fallback for unknown theme" do
      defaults = Defaults.get_theme_defaults("999")

      assert defaults.background_type == "gradient"
    end

    test "build_initial_customization/3 creates new when nil" do
      customization = Defaults.build_initial_customization(1, "1", nil)

      assert customization.profile_id == 1
      assert customization.theme_id == "1"
      assert customization.color_scheme == "default"
    end

    test "build_initial_customization/3 returns existing when present" do
      existing = %ThemeCustomizationSchema{
        profile_id: 1,
        theme_id: "1",
        color_scheme: "purple",
        background_type: "color",
        background_value: "#ff0000"
      }

      result = Defaults.build_initial_customization(1, "1", existing)

      assert result.color_scheme == "purple"
    end

    test "get_fallback_customization/1 creates defaults with nil profile" do
      fallback = Defaults.get_fallback_customization("1")

      assert fallback.profile_id == nil
      assert fallback.theme_id == "1"
      assert fallback.color_scheme == "default"
    end

    test "merge_with_defaults/2 fills in nil values" do
      partial = %ThemeCustomizationSchema{
        profile_id: 1,
        theme_id: "1",
        color_scheme: nil,
        background_type: nil,
        background_value: nil
      }

      merged = Defaults.merge_with_defaults(partial, "1")

      assert merged.color_scheme == "default"
      assert merged.background_type == "gradient"
      assert merged.background_value == "gradient_1"
    end

    test "theme_supports_feature?/2 checks Quill features" do
      assert Defaults.theme_supports_feature?("1", :video_backgrounds) == true
      assert Defaults.theme_supports_feature?("1", :image_backgrounds) == true
      assert Defaults.theme_supports_feature?("1", :gradient_backgrounds) == true
    end

    test "theme_supports_feature?/2 checks Rhythm features" do
      assert Defaults.theme_supports_feature?("2", :video_backgrounds) == true
    end

    test "theme_supports_feature?/2 returns false for unknown theme" do
      assert Defaults.theme_supports_feature?("999", :video_backgrounds) == false
    end

    test "get_recommended_background_type/1 returns theme-appropriate type" do
      assert Defaults.get_recommended_background_type("1") == "gradient"
      assert Defaults.get_recommended_background_type("2") == "video"
    end
  end
end
