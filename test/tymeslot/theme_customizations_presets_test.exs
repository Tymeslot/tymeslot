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

    test "take/2 returns the named presets in the order given, leaving out unknown ids" do
      assert [{"ocean", %{name: "Ocean Breeze"}}, {"default", %{name: "Default Turquoise"}}] =
               Presets.take(:color_scheme, ["ocean", "nope", "default"])
    end

    test "find_preset_by_id/2 finds color scheme" do
      preset = Presets.find_preset_by_id(:color_scheme, "purple")

      assert preset.name == "Purple Dream"
      assert Map.has_key?(preset, :colors)
    end

    test "every colour scheme names its mode, and only a light one carries dark colours" do
      schemes = Map.values(Presets.get_color_schemes())

      assert schemes != []
      assert Enum.reject(schemes, &(&1.mode in [:light, :dark])) == []

      # A light scheme's dark counterpart is optional; a dark scheme has none.
      assert Enum.filter(schemes, &(&1.mode == :dark and Map.has_key?(&1, :dark_colors))) == []

      assert Enum.reject(schemes, fn scheme ->
               scheme.mode == :dark or not Map.has_key?(scheme, :dark_colors) or
                 Map.keys(scheme.dark_colors) == Map.keys(scheme.colors)
             end) == []
    end

    test "find_preset_by_id/2 finds gradient" do
      preset = Presets.find_preset_by_id(:gradient, "gradient_1")

      assert preset.name == "Aurora"
      assert preset.value =~ "linear-gradient"
    end

    test "find_preset_by_id/2 returns nil for unknown type" do
      assert Presets.find_preset_by_id(:unknown, "test") == nil
    end

    test "every image preset ships in the one preset image directory" do
      dir = Application.app_dir(:tymeslot, "priv/static/images/themes/backgrounds")

      missing =
        Presets.get_image_presets()
        |> Map.values()
        |> Enum.flat_map(&[&1.file, &1.thumbnail])
        |> Enum.reject(&File.exists?(Path.join(dir, &1)))

      assert Presets.get_image_presets() != %{}
      assert missing == []
    end
  end
end
