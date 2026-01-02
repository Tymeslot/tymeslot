defmodule Tymeslot.ThemeCustomizationsCssGenerationTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.DatabaseSchemas.ThemeCustomizationSchema
  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations

  describe "ThemeCustomizations CSS generation" do
    setup do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      %{profile: profile}
    end

    test "generate_theme_css/2 creates CSS from customization", %{profile: profile} do
      {:ok, customization} =
        ThemeCustomizations.create_theme_customization(profile.id, "1", %{
          "color_scheme" => "purple",
          "background_type" => "gradient",
          "background_value" => "gradient_1"
        })

      css = ThemeCustomizations.generate_theme_css("1", customization)

      assert is_binary(css)
    end

    test "get_defaults/1 returns theme-specific defaults" do
      defaults_quill = ThemeCustomizations.get_defaults("1")
      defaults_rhythm = ThemeCustomizations.get_defaults("2")

      assert is_map(defaults_quill)
      assert is_map(defaults_rhythm)
    end

    test "to_map/1 converts customization to map", %{profile: profile} do
      customization = %ThemeCustomizationSchema{
        profile_id: profile.id,
        theme_id: "1",
        color_scheme: "purple",
        background_type: "gradient",
        background_value: "gradient_1"
      }

      map = ThemeCustomizations.to_map(customization)

      assert map["color_scheme"] == "purple"
      assert map["background_type"] == "gradient"
    end

    test "to_map/1 handles nil" do
      assert ThemeCustomizations.to_map(nil) == %{}
    end
  end
end
