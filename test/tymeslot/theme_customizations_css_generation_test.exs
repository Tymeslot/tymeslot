defmodule Tymeslot.ThemeCustomizationsCssGenerationTest do
  use Tymeslot.DataCase, async: true
  @moduletag :utils

  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Capability
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

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

      assert css =~ "--theme-background:"
    end

    test "get_defaults/1 returns theme-specific defaults" do
      assert ThemeCustomizations.get_defaults("1") == %{
               "background_type" => "gradient",
               "background_value" => "gradient_1",
               "color_scheme" => "default"
             }

      assert ThemeCustomizations.get_defaults("2") == %{
               "background_type" => "gradient",
               "background_value" => "gradient_1",
               "color_scheme" => "default"
             }
    end

    test "capability options include backgrounds and colors" do
      options = Capability.get_customization_options("1")

      assert Map.has_key?(options, :color)
      assert Map.has_key?(options, :background)

      background_keys = Enum.map(options.background, & &1.key)
      assert "image" in background_keys
      assert "video" in background_keys
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

    # Regression guard: a `</style>` payload in a field must never reach the
    # rendered stylesheet. This test exercises per-field validation — the
    # background_value is rejected by `valid_color?` before CSS is assembled,
    # so no payload reaches `sanitize_css`. The sanitize_css gate itself is
    # unit-tested in theme_customizations_validation_test.exs.
    test "generate_theme_css/2 never emits a </style> breakout payload", %{profile: profile} do
      customization = %ThemeCustomizationSchema{
        profile_id: profile.id,
        theme_id: "1",
        color_scheme: "purple",
        background_type: "color",
        background_value: "</style><script>alert(1)</script>"
      }

      css = ThemeCustomizations.generate_theme_css("1", customization)

      # Per-field validation rejects the bogus background_value, and the
      # output contains no attacker payload.
      refute css =~ "</style"
      refute css =~ "<script"
    end
  end
end
