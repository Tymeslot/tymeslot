defmodule Tymeslot.ThemeCustomizationsBackgroundOperationsTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.DatabaseSchemas.ThemeCustomizationSchema
  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations

  describe "ThemeCustomizations background operations" do
    setup do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      %{profile: profile}
    end

    test "apply_background_change/5 updates to gradient", %{profile: profile} do
      current = %ThemeCustomizationSchema{
        profile_id: profile.id,
        theme_id: "1",
        color_scheme: "default",
        background_type: "color",
        background_value: "#000000"
      }

      {:ok, updated} =
        ThemeCustomizations.apply_background_change(
          profile.id,
          "1",
          current,
          "gradient",
          "gradient_2"
        )

      assert updated.background_type == "gradient"
      assert updated.background_value == "gradient_2"
    end

    test "apply_background_change/5 updates to solid color", %{profile: profile} do
      current = %ThemeCustomizationSchema{
        profile_id: profile.id,
        theme_id: "1",
        color_scheme: "default",
        background_type: "gradient",
        background_value: "gradient_1"
      }

      {:ok, updated} =
        ThemeCustomizations.apply_background_change(
          profile.id,
          "1",
          current,
          "color",
          "#ff5500"
        )

      assert updated.background_type == "color"
      assert updated.background_value == "#ff5500"
    end

    test "apply_background_change/5 updates to preset video", %{profile: profile} do
      current = %ThemeCustomizationSchema{
        profile_id: profile.id,
        theme_id: "2",
        color_scheme: "default",
        background_type: "gradient",
        background_value: "gradient_1"
      }

      {:ok, updated} =
        ThemeCustomizations.apply_background_change(
          profile.id,
          "2",
          current,
          "video",
          "preset:rhythm-default"
        )

      assert updated.background_type == "video"
      assert updated.background_value == "preset:rhythm-default"
    end

    test "apply_background_change/5 updates to preset image", %{profile: profile} do
      current = %ThemeCustomizationSchema{
        profile_id: profile.id,
        theme_id: "1",
        color_scheme: "default",
        background_type: "gradient",
        background_value: "gradient_1"
      }

      {:ok, updated} =
        ThemeCustomizations.apply_background_change(
          profile.id,
          "1",
          current,
          "image",
          "preset:artistic-studio"
        )

      assert updated.background_type == "image"
      assert updated.background_value == "preset:artistic-studio"
    end

    test "get_gradient_css/1 returns gradient CSS for valid preset" do
      css = ThemeCustomizations.get_gradient_css("gradient_1")

      assert is_binary(css)
      assert String.contains?(css, "linear-gradient")
    end

    test "get_gradient_css/1 returns nil for invalid preset" do
      assert ThemeCustomizations.get_gradient_css("nonexistent") == nil
    end

    test "get_background_description/1 for gradient type", %{profile: profile} do
      customization = %ThemeCustomizationSchema{
        profile_id: profile.id,
        theme_id: "1",
        background_type: "gradient",
        background_value: "gradient_1"
      }

      description = ThemeCustomizations.get_background_description(customization)

      assert description =~ "Gradient:"
    end

    test "get_background_description/1 for color type", %{profile: profile} do
      customization = %ThemeCustomizationSchema{
        profile_id: profile.id,
        theme_id: "1",
        background_type: "color",
        background_value: "#ff5500"
      }

      description = ThemeCustomizations.get_background_description(customization)

      assert description =~ "Solid Color:"
    end
  end
end
