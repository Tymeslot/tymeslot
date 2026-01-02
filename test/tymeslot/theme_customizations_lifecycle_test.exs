defmodule Tymeslot.ThemeCustomizationsLifecycleTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.DatabaseSchemas.ThemeCustomizationSchema
  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations

  describe "ThemeCustomizations lifecycle" do
    setup do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      %{profile: profile, user: user}
    end

    test "initialize_customization/2 returns defaults for new profile", %{profile: profile} do
      result = ThemeCustomizations.initialize_customization(profile.id, "1")

      assert %{
               customization: %ThemeCustomizationSchema{},
               original: %ThemeCustomizationSchema{},
               presets: presets,
               defaults: defaults
             } = result

      assert Map.has_key?(presets, :color_schemes)
      assert Map.has_key?(presets, :gradients)
      assert defaults.background_type == "gradient"
    end

    test "initialize_customization/2 returns existing customization when saved", %{profile: profile} do
      attrs = %{
        "color_scheme" => "purple",
        "background_type" => "gradient",
        "background_value" => "gradient_2"
      }

      {:ok, _saved} = ThemeCustomizations.create_theme_customization(profile.id, "1", attrs)

      result = ThemeCustomizations.initialize_customization(profile.id, "1")

      assert result.customization.color_scheme == "purple"
      assert result.customization.background_value == "gradient_2"
    end

    test "get_all_by_profile_id/1 returns all customizations for a profile", %{profile: profile} do
      {:ok, _} =
        ThemeCustomizations.create_theme_customization(profile.id, "1", %{
          "color_scheme" => "purple",
          "background_type" => "gradient",
          "background_value" => "gradient_1"
        })

      {:ok, _} =
        ThemeCustomizations.create_theme_customization(profile.id, "2", %{
          "color_scheme" => "ocean",
          "background_type" => "video",
          "background_value" => "preset:rhythm-default"
        })

      customizations = ThemeCustomizations.get_all_by_profile_id(profile.id)

      assert length(customizations) == 2
    end

    test "reset_to_defaults/2 removes customization", %{profile: profile} do
      {:ok, _} =
        ThemeCustomizations.create_theme_customization(profile.id, "1", %{
          "color_scheme" => "sunset",
          "background_type" => "gradient",
          "background_value" => "gradient_3"
        })

      assert {:ok, _} = ThemeCustomizations.reset_to_defaults(profile.id, "1")
      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1") == nil
    end

    test "reset_to_defaults/2 returns :no_customization when nothing to reset", %{
      profile: profile
    } do
      assert {:ok, :no_customization} = ThemeCustomizations.reset_to_defaults(profile.id, "1")
    end

    test "get_for_user/2 returns customization by user_id", %{user: user, profile: profile} do
      {:ok, _} =
        ThemeCustomizations.create_theme_customization(profile.id, "1", %{
          "color_scheme" => "forest",
          "background_type" => "gradient",
          "background_value" => "gradient_4"
        })

      customization = ThemeCustomizations.get_for_user(user.id, "1")

      assert customization.color_scheme == "forest"
    end

    test "get_for_user/2 returns nil for non-existent user", %{} do
      assert ThemeCustomizations.get_for_user(999_999, "1") == nil
    end
  end
end
