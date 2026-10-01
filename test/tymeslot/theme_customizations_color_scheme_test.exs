defmodule Tymeslot.ThemeCustomizationsColorSchemeTest do
  use Tymeslot.DataCase, async: true
  @moduletag :utils

  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations

  describe "ThemeCustomizations color scheme operations" do
    setup do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      %{profile: profile}
    end

    test "apply_option/4 creates customization with scheme", %{profile: profile} do
      {:ok, updated} = scheme(profile, "purple")

      assert updated.settings["color_scheme"] == "purple"
    end
  end

  describe "custom palette" do
    setup do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      %{profile: profile}
    end

    test "apply_option/4 persists custom seed", %{profile: profile} do
      {:ok, updated} = seed(profile, "#FF6B35")

      assert updated.settings["custom_palette_seed"] == "#ff6b35"
      # color_scheme is unchanged: seed presence signals custom mode
      assert updated.settings["color_scheme"] == "default"
    end

    test "apply_option/4 rejects invalid hex", %{profile: profile} do
      assert {:error, "Could not save your theme customisation. Please try again."} =
               seed(profile, "not-hex")

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1") == nil
    end

    test "apply_option/4 with the brand default seed stores it", %{profile: profile} do
      {:ok, updated} = seed(profile, ThemeCustomizations.default_custom_palette_seed())

      assert updated.settings["custom_palette_seed"] == "#06b6d4"
    end

    test "apply_option/4 with the stored seed keeps it", %{profile: profile} do
      {:ok, _saved} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "color_scheme" => "default",
          "custom_palette_seed" => "#ff6b35",
          "background_type" => "gradient",
          "background_value" => "gradient_1"
        })

      current = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")

      {:ok, updated} = seed(profile, current.settings["custom_palette_seed"])

      assert updated.settings["custom_palette_seed"] == "#ff6b35"
    end

    # Regression for seed not cleared when switching back to a preset
    test "apply_option/4 clears custom_palette_seed when switching to a preset",
         %{profile: profile} do
      # Step 1: store a custom seed
      {:ok, with_seed} = seed(profile, "#ff6b35")

      assert with_seed.settings["custom_palette_seed"] == "#ff6b35"

      # Step 2: switch back to a preset scheme
      {:ok, updated} = scheme(profile, "purple")

      assert updated.settings["custom_palette_seed"] == nil
      assert updated.settings["color_scheme"] == "purple"

      # Step 3: the page's tokens should reflect the preset, not the old seed
      %{vars: vars} = ThemeCustomizations.tokens("1", updated)
      assert vars["--theme-primary"] == "#8b5cf6"
      refute "#ff6b35" in Map.values(vars)
    end
  end

  defp scheme(profile, scheme_id),
    do:
      ThemeCustomizations.apply_option(profile.id, "1", :palette, %{
        "field" => "scheme",
        "value" => scheme_id
      })

  defp seed(profile, hex),
    do:
      ThemeCustomizations.apply_option(profile.id, "1", :palette, %{
        "field" => "seed",
        "value" => hex
      })
end
