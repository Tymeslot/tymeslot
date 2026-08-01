defmodule Tymeslot.ThemeCustomizationsColorSchemeTest do
  use Tymeslot.DataCase, async: true
  @moduletag :utils

  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  describe "ThemeCustomizations color scheme operations" do
    setup do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      %{profile: profile}
    end

    test "apply_color_scheme_change/4 creates customization with scheme", %{profile: profile} do
      current = %ThemeCustomizationSchema{
        profile_id: profile.id,
        theme_id: "1",
        color_scheme: "default",
        background_type: "gradient",
        background_value: "gradient_1"
      }

      {:ok, updated} =
        ThemeCustomizations.apply_color_scheme_change(profile.id, "1", current, "purple")

      assert updated.color_scheme == "purple"
    end

    test "get_color_scheme_css/1 returns CSS variables for valid scheme" do
      css = ThemeCustomizations.get_color_scheme_css("purple")

      assert css =~ "--theme-primary:"
      assert css =~ "#8b5cf6"
    end

    test "get_color_scheme_css/1 returns nil for invalid scheme" do
      assert ThemeCustomizations.get_color_scheme_css("nonexistent") == nil
    end
  end

  describe "custom palette" do
    setup do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      %{profile: profile}
    end

    test "apply_custom_palette_change/4 persists custom seed", %{profile: profile} do
      current = %ThemeCustomizationSchema{
        profile_id: profile.id,
        theme_id: "1",
        color_scheme: "default",
        background_type: "gradient",
        background_value: "gradient_1"
      }

      {:ok, updated} =
        ThemeCustomizations.apply_custom_palette_change(profile.id, "1", current, "#FF6B35")

      assert updated.custom_palette_seed == "#ff6b35"
      # color_scheme is unchanged — seed presence signals custom mode
      assert updated.color_scheme == "default"
    end

    test "apply_custom_palette_change/4 rejects invalid hex", %{profile: profile} do
      current = %ThemeCustomizationSchema{
        profile_id: profile.id,
        theme_id: "1",
        color_scheme: "default",
        background_type: "gradient",
        background_value: "gradient_1"
      }

      assert {:error, _msg} =
               ThemeCustomizations.apply_custom_palette_change(
                 profile.id,
                 "1",
                 current,
                 "not-hex"
               )
    end

    test "apply_color_scheme_change/4 with 'custom' uses brand default seed when none stored",
         %{profile: profile} do
      current = %ThemeCustomizationSchema{
        profile_id: profile.id,
        theme_id: "1",
        color_scheme: "default",
        background_type: "gradient",
        background_value: "gradient_1"
      }

      {:ok, updated} =
        ThemeCustomizations.apply_color_scheme_change(profile.id, "1", current, "custom")

      assert updated.custom_palette_seed == "#06b6d4"
    end

    test "apply_color_scheme_change/4 with 'custom' preserves existing seed", %{profile: profile} do
      {:ok, _saved} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "color_scheme" => "default",
          "custom_palette_seed" => "#ff6b35",
          "background_type" => "gradient",
          "background_value" => "gradient_1"
        })

      current = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")

      {:ok, updated} =
        ThemeCustomizations.apply_color_scheme_change(profile.id, "1", current, "custom")

      assert updated.custom_palette_seed == "#ff6b35"
    end

    test "get_color_scheme_css/1 with map derives CSS from custom seed when seed is present" do
      customization = %{
        "color_scheme" => "default",
        "custom_palette_seed" => "#ff6b35"
      }

      css = ThemeCustomizations.get_color_scheme_css(customization)

      assert css =~ "--theme-primary: #ff6b35"
      assert css =~ "--theme-background:"
      assert css =~ "--theme-text:"
    end

    # Regression for seed not cleared when switching back to a preset
    test "apply_color_scheme_change/4 clears custom_palette_seed when switching to a preset",
         %{profile: profile} do
      # Step 1: store a custom seed
      {:ok, with_seed} =
        ThemeCustomizations.apply_custom_palette_change(
          profile.id,
          "1",
          %{
            profile_id: profile.id,
            theme_id: "1",
            color_scheme: "default",
            custom_palette_seed: nil,
            background_type: "gradient",
            background_value: "gradient_1",
            background_image_path: nil,
            background_video_path: nil
          },
          "#ff6b35"
        )

      assert with_seed.custom_palette_seed == "#ff6b35"

      # Step 2: switch back to a preset scheme
      {:ok, updated} =
        ThemeCustomizations.apply_color_scheme_change(profile.id, "1", with_seed, "purple")

      assert updated.custom_palette_seed == nil
      assert updated.color_scheme == "purple"

      # Step 3: CSS should reflect the preset, not the old seed
      css = ThemeCustomizations.get_color_scheme_css(updated)
      assert css =~ "#8b5cf6"
      refute css =~ "#ff6b35"
    end
  end

  describe "resolve_active_scheme/2" do
    setup do
      presets = %{
        color_schemes: %{
          "purple" => %{
            name: "Purple Dream",
            colors: %{
              primary: "#8b5cf6",
              primary_hover: "#7c3aed",
              secondary: "#a78bfa",
              accent: "#c084fc",
              background: "#1e1b4b",
              surface: "rgba(46, 38, 84, 0.5)",
              text: "#ede9fe",
              text_secondary: "#c4b5fd"
            }
          }
        }
      }

      %{presets: presets}
    end

    test "returns derived palette when seed is present", %{presets: presets} do
      customization = %{
        color_scheme: "purple",
        custom_palette_seed: "#ff6b35"
      }

      result = ThemeCustomizations.resolve_active_scheme(customization, presets)

      assert result.name == "Custom"
      assert result.colors.primary == "#ff6b35"
    end

    test "returns preset scheme when no seed is set and scheme_id is known", %{presets: presets} do
      customization = %{
        color_scheme: "purple",
        custom_palette_seed: nil
      }

      result = ThemeCustomizations.resolve_active_scheme(customization, presets)

      assert result.name == "Purple Dream"
      assert result.colors.primary == "#8b5cf6"
    end

    test "returns nil when no seed and scheme_id is unknown", %{presets: presets} do
      customization = %{
        color_scheme: "nonexistent",
        custom_palette_seed: nil
      }

      assert ThemeCustomizations.resolve_active_scheme(customization, presets) == nil
    end
  end
end
