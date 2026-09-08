defmodule Tymeslot.ThemeCustomizationsPresetsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :utils

  alias Tymeslot.ThemeCustomizations.Presets

  describe "Presets module" do
    test "get_color_schemes/0 returns all color schemes" do
      schemes = Presets.get_color_schemes()

      assert Map.has_key?(schemes, "default")
      assert Map.has_key?(schemes, "purple")
      assert Map.has_key?(schemes, "sunset")
      assert Map.has_key?(schemes, "ocean")
    end

    test "get_gradient_presets/0 returns all gradients" do
      gradients = Presets.get_gradient_presets()

      assert Map.has_key?(gradients, "gradient_1")
      assert Map.has_key?(gradients, "gradient_2")
    end

    test "get_video_presets/0 returns video presets" do
      videos = Presets.get_video_presets()

      assert Map.has_key?(videos, "preset:rhythm-default")
    end

    test "get_image_presets/0 returns image presets" do
      images = Presets.get_image_presets()

      assert Map.has_key?(images, "preset:artistic-studio")
    end

    test "get_all_presets/0 returns organized presets" do
      all = Presets.get_all_presets()

      assert Map.has_key?(all, :color_schemes)
      assert Map.has_key?(all, :gradients)
      assert Map.has_key?(all, :videos)
      assert Map.has_key?(all, :images)
    end

    test "find_preset_by_id/2 finds color scheme" do
      preset = Presets.find_preset_by_id(:color_scheme, "purple")

      assert preset.name == "Purple Dream"
      assert Map.has_key?(preset, :colors)
    end

    test "find_preset_by_id/2 finds gradient" do
      preset = Presets.find_preset_by_id(:gradient, "gradient_1")

      assert preset.name == "Aurora"
      assert preset.value =~ "linear-gradient"
    end

    test "find_preset_by_id/2 returns nil for unknown type" do
      assert Presets.find_preset_by_id(:unknown, "test") == nil
    end
  end
end
