defmodule Tymeslot.ThemeCustomizationsColorSchemeTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.DatabaseSchemas.ThemeCustomizationSchema
  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations

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
end
