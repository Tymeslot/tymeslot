defmodule Tymeslot.ThemeCustomizationsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :utils

  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations

  describe "theme customizations" do
    setup do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      %{profile: profile}
    end

    test "create_theme_customization/3 creates a customization for a theme", %{profile: profile} do
      attrs = %{
        "color_scheme" => "purple",
        "background_type" => "gradient",
        "background_value" => "gradient_1"
      }

      assert {:ok, customization} =
               ThemeCustomizations.create_theme_customization(profile.id, "1", attrs)

      assert customization.theme_id == "1"
      assert customization.color_scheme == "purple"
      assert customization.background_type == "gradient"
      assert customization.background_value == "gradient_1"
    end

    test "get_by_profile_and_theme/2 returns the customization", %{profile: profile} do
      attrs = %{
        "color_scheme" => "ocean",
        "background_type" => "color",
        "background_value" => "#082f49"
      }

      {:ok, _result} = ThemeCustomizations.create_theme_customization(profile.id, "2", attrs)

      customization = ThemeCustomizations.get_by_profile_and_theme(profile.id, "2")
      assert customization.theme_id == "2"
      assert customization.color_scheme == "ocean"
      assert customization.background_type == "color"
      assert customization.background_value == "#082f49"
    end

    test "upsert_theme_customization/3 updates existing customization", %{profile: profile} do
      # Create initial customization
      initial_attrs = %{
        "color_scheme" => "default",
        "background_type" => "gradient",
        "background_value" => "gradient_1"
      }

      {:ok, _result} =
        ThemeCustomizations.create_theme_customization(profile.id, "1", initial_attrs)

      # Update it
      update_attrs = %{
        "color_scheme" => "sunset",
        "background_type" => "gradient",
        "background_value" => "gradient_3"
      }

      {:ok, updated} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", update_attrs)

      assert updated.color_scheme == "sunset"
      assert updated.background_value == "gradient_3"
    end

    test "delete_theme_customization/1 removes customization", %{profile: profile} do
      attrs = %{
        "color_scheme" => "forest",
        "background_type" => "gradient",
        "background_value" => "gradient_4"
      }

      {:ok, customization} =
        ThemeCustomizations.create_theme_customization(profile.id, "2", attrs)

      assert {:ok, _result} = ThemeCustomizations.delete_theme_customization(customization)

      # Check customization is deleted
      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "2") == nil
    end

  end
end
