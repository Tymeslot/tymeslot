defmodule Tymeslot.ThemeCustomizationsPresetsTest do
  use Tymeslot.DataCase, async: true

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

    test "validate_preset_exists/2 validates existing preset" do
      assert Presets.validate_preset_exists(:color_scheme, "purple") == :ok
      assert Presets.validate_preset_exists(:gradient, "gradient_1") == :ok
    end

    test "validate_preset_exists/2 returns error for non-existent" do
      assert Presets.validate_preset_exists(:color_scheme, "nonexistent") ==
               {:error, :preset_not_found}
    end

    test "get_preset_by_background/2 for gradient" do
      preset = Presets.get_preset_by_background("gradient", "gradient_1")

      assert preset.name == "Aurora"
    end

    test "get_preset_by_background/2 for preset video" do
      preset = Presets.get_preset_by_background("video", "preset:rhythm-default")

      assert preset.name == "Rhythm Default"
    end

    test "get_preset_by_background/2 for preset image" do
      preset = Presets.get_preset_by_background("image", "preset:artistic-studio")

      assert preset.name == "Artistic Studio"
    end

    test "get_preset_by_background/2 returns nil for custom backgrounds" do
      assert Presets.get_preset_by_background("image", "custom/path.jpg") == nil
      assert Presets.get_preset_by_background("video", "custom/path.mp4") == nil
    end

    test "list_preset_ids/1 returns IDs for each type" do
      assert "purple" in Presets.list_preset_ids(:color_scheme)
      assert "gradient_1" in Presets.list_preset_ids(:gradient)
      assert "preset:rhythm-default" in Presets.list_preset_ids(:video)
      assert "preset:artistic-studio" in Presets.list_preset_ids(:image)
    end

    test "list_preset_ids/1 returns empty list for unknown type" do
      assert Presets.list_preset_ids(:unknown) == []
    end

    test "get_preset_metadata/2 returns metadata" do
      metadata = Presets.get_preset_metadata(:color_scheme, "purple")

      assert metadata.name == "Purple Dream"
      assert metadata.id == "purple"
      assert metadata.type == :color_scheme
    end

    test "get_preset_metadata/2 returns nil for non-existent" do
      assert Presets.get_preset_metadata(:color_scheme, "nonexistent") == nil
    end

    test "preset_value?/1 identifies preset values" do
      assert Presets.preset_value?("preset:rhythm-default") == true
      assert Presets.preset_value?("gradient_1") == false
      assert Presets.preset_value?(nil) == false
    end

    test "extract_preset_id/1 extracts ID from preset value" do
      assert Presets.extract_preset_id("preset:rhythm-default") == "rhythm-default"
      assert Presets.extract_preset_id("gradient_1") == "gradient_1"
      assert Presets.extract_preset_id(nil) == nil
    end

    test "format_as_preset_value/1 formats as preset" do
      assert Presets.format_as_preset_value("rhythm-default") == "preset:rhythm-default"
      assert Presets.format_as_preset_value("preset:already") == "preset:already"
      assert Presets.format_as_preset_value(nil) == nil
    end

    test "get_recommended_presets_for_theme/1 returns theme recommendations" do
      quill_recs = Presets.get_recommended_presets_for_theme("1")
      rhythm_recs = Presets.get_recommended_presets_for_theme("2")

      assert Map.has_key?(quill_recs, :gradients)
      assert Map.has_key?(rhythm_recs, :videos)
    end

    test "get_recommended_presets_for_theme/1 returns empty for unknown theme" do
      unknown_recs = Presets.get_recommended_presets_for_theme("999")

      assert unknown_recs == %{gradients: [], videos: [], images: []}
    end
  end
end
