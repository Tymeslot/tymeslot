defmodule Tymeslot.ThemeCustomizationsLifecycleTest do
  use Tymeslot.DataCase, async: true
  @moduletag :utils

  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

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
               original: %ThemeCustomizationSchema{}
             } = result

      assert result.customization.settings["background_value"] == "gradient_1"
      assert result.customization.profile_id == profile.id
    end

    test "initialize_customization/2 returns existing customization when saved", %{
      profile: profile
    } do
      attrs = %{
        "color_scheme" => "purple",
        "background_type" => "gradient",
        "background_value" => "gradient_2"
      }

      {:ok, _saved} = ThemeCustomizations.upsert_theme_customization(profile.id, "1", attrs)

      result = ThemeCustomizations.initialize_customization(profile.id, "1")

      assert result.customization.settings["color_scheme"] == "purple"
      assert result.customization.settings["background_value"] == "gradient_2"
    end

    test "get_for_user/2 returns customization by user_id", %{user: user, profile: profile} do
      {:ok, _result} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "color_scheme" => "forest",
          "background_type" => "gradient",
          "background_value" => "gradient_4"
        })

      customization = ThemeCustomizations.get_for_user(user.id, "1")

      assert customization.settings["color_scheme"] == "forest"
    end

    test "get_for_user/2 returns nil for non-existent user", %{} do
      assert ThemeCustomizations.get_for_user(999_999, "1") == nil
    end
  end
end
