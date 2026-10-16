defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.PanelStateTest do
  @moduledoc """
  The built-in panels own their UI state: which background tab is open,
  whether a disclosure is expanded, and what each UI event does.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Options.Accent
  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.AccentPanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.BackgroundPanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.PalettePanel

  @background %{key: :background, module: Background, kinds: [:gradient, :color, :video]}
  @palette %{key: :palette, module: Palette, schemes: ["default"]}

  defp customization(settings), do: %ThemeCustomizationSchema{settings: settings}

  describe "BackgroundPanel" do
    test "opens on the stored kind, else on the group's first kind" do
      assert %{browsing_type: "video", custom_picker_open: false} =
               BackgroundPanel.ui(
                 @background,
                 customization(%{"background_type" => "video"}),
                 %{}
               )

      assert %{browsing_type: "gradient"} =
               BackgroundPanel.ui(
                 @background,
                 customization(%{"background_type" => "image"}),
                 %{}
               )
    end

    test "a save moves to the saved kind and leaves the colour disclosure as it was" do
      ui = %{browsing_type: "gradient", custom_picker_open: true}

      assert BackgroundPanel.ui(@background, customization(%{"background_type" => "color"}), ui) ==
               %{browsing_type: "color", custom_picker_open: true}
    end

    test "switches tab only to a kind the group offers" do
      ui = %{browsing_type: "gradient", custom_picker_open: false}

      assert {:ui, %{browsing_type: "video"}} =
               BackgroundPanel.handle_ui(
                 "theme:set_browsing_type",
                 %{"type" => "video"},
                 @background,
                 ui,
                 customization(%{})
               )

      assert BackgroundPanel.handle_ui(
               "theme:set_browsing_type",
               %{"type" => "image"},
               @background,
               ui,
               customization(%{})
             ) == :ignore
    end

    test "toggles the custom colour disclosure" do
      assert {:ui, %{custom_picker_open: true}} =
               BackgroundPanel.handle_ui(
                 "theme:toggle_custom_picker",
                 %{},
                 @background,
                 %{browsing_type: "color", custom_picker_open: false},
                 customization(%{})
               )
    end

    test "names its writes as before" do
      assert BackgroundPanel.telemetry(@background, "color", "#123456") ==
               {:background_changed, "background", %{type: "color", value: "#123456"}}
    end
  end

  describe "PalettePanel" do
    test "the seed picker is open exactly when a seed is stored" do
      assert PalettePanel.ui(@palette, customization(%{"custom_palette_seed" => "#ff6b35"}), %{}) ==
               %{palette_picker_open: true}

      assert PalettePanel.ui(
               @palette,
               customization(%{"color_scheme" => "default"}),
               %{palette_picker_open: true}
             ) == %{palette_picker_open: false}
    end

    test "Custom without a stored seed writes the default seed" do
      assert PalettePanel.handle_ui(
               "theme:toggle_palette_picker",
               %{},
               @palette,
               %{palette_picker_open: false},
               customization(%{"color_scheme" => "default"})
             ) == {:set, "seed", ThemeCustomizations.default_custom_palette_seed()}
    end

    test "Custom with a stored seed only toggles the picker" do
      assert PalettePanel.handle_ui(
               "theme:toggle_palette_picker",
               %{},
               @palette,
               %{palette_picker_open: true},
               customization(%{"custom_palette_seed" => "#ff6b35"})
             ) == {:ui, %{palette_picker_open: false}}
    end

    test "names its writes as before" do
      assert PalettePanel.telemetry(@palette, "seed", "#aabbcc") ==
               {:palette_seed_changed, "palette_seed", %{seed: "#aabbcc"}}

      assert PalettePanel.telemetry(@palette, "scheme", "ocean") ==
               {:color_scheme_changed, "color_scheme", %{scheme_id: "ocean"}}
    end
  end

  describe "AccentPanel" do
    @accent %{key: :accent, module: Accent, presets: ~w(tymeslot cobalt), default: "tymeslot"}

    test "the colour widget is open exactly while a custom colour is the accent" do
      assert AccentPanel.ui(@accent, customization(%{"accent" => "#123456"}), %{}) ==
               %{accent_picker_open: true}

      assert AccentPanel.ui(
               @accent,
               customization(%{"accent" => "cobalt"}),
               %{accent_picker_open: true}
             ) == %{accent_picker_open: false}

      assert AccentPanel.ui(@accent, customization(%{}), %{}) == %{accent_picker_open: false}
    end

    test "Custom on a preset saves the preset's colour as the custom accent" do
      assert AccentPanel.handle_ui(
               "theme:toggle_accent_picker",
               %{},
               @accent,
               %{accent_picker_open: false},
               customization(%{"accent" => "cobalt"})
             ) == {:set, "custom", "#2563eb"}
    end

    test "Custom on a custom colour only shows or hides the widget" do
      assert AccentPanel.handle_ui(
               "theme:toggle_accent_picker",
               %{},
               @accent,
               %{accent_picker_open: true},
               customization(%{"accent" => "#123456"})
             ) == {:ui, %{accent_picker_open: false}}
    end

    test "ignores any other UI event" do
      assert AccentPanel.handle_ui(
               "theme:toggle_palette_picker",
               %{},
               @accent,
               %{accent_picker_open: false},
               customization(%{})
             ) == :ignore
    end
  end
end
