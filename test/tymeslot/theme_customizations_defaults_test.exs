defmodule Tymeslot.ThemeCustomizationsDefaultsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :utils

  alias Tymeslot.ThemeCustomizations.Defaults
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

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
  end
end
