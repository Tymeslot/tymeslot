defmodule Tymeslot.ThemeCustomizationsTest do
  use Tymeslot.DataCase

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

      {:ok, _} = ThemeCustomizations.create_theme_customization(profile.id, "2", attrs)

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

      {:ok, _} = ThemeCustomizations.create_theme_customization(profile.id, "1", initial_attrs)

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

      assert {:ok, _} = ThemeCustomizations.delete_theme_customization(customization)

      # Check customization is deleted
      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "2") == nil
    end

    test "get_color_scheme_css/1 returns CSS variables", %{} do
      css = ThemeCustomizations.get_color_scheme_css("purple")
      assert css =~ "--theme-primary: #8b5cf6;"
      assert css =~ "--theme-secondary: #a78bfa;"
      assert css =~ "--theme-background: #1e1b4b;"
    end

    test "get_gradient_css/1 returns gradient CSS", %{} do
      css = ThemeCustomizations.get_gradient_css("gradient_1")
      assert css == "linear-gradient(135deg, #667eea 0%, #764ba2 100%)"
    end
  end
end
