defmodule Tymeslot.ThemeCustomizationsBackgroundOperationsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :utils

  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations

  describe "ThemeCustomizations background operations" do
    setup do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      %{profile: profile}
    end

    test "apply_option/4 updates a colour background to a gradient", %{profile: profile} do
      {:ok, _colour} = background(profile, "1", "color", "#000000")

      {:ok, updated} = background(profile, "1", "gradient", "gradient_2")

      assert updated.settings["background_type"] == "gradient"
      assert updated.settings["background_value"] == "gradient_2"
    end

    test "apply_option/4 updates to solid color", %{profile: profile} do
      {:ok, updated} = background(profile, "1", "color", "#ff5500")

      assert updated.settings["background_type"] == "color"
      assert updated.settings["background_value"] == "#ff5500"
    end

    test "apply_option/4 updates to preset video", %{profile: profile} do
      {:ok, updated} = background(profile, "2", "video", "preset:rhythm-default")

      assert updated.settings["background_type"] == "video"
      assert updated.settings["background_value"] == "preset:rhythm-default"
    end

    test "apply_option/4 updates to preset image", %{profile: profile} do
      {:ok, updated} = background(profile, "1", "image", "preset:artistic-studio")

      assert updated.settings["background_type"] == "image"
      assert updated.settings["background_value"] == "preset:artistic-studio"
    end
  end

  defp background(profile, theme_id, kind, value),
    do:
      ThemeCustomizations.apply_option(profile.id, theme_id, :background, %{
        "field" => kind,
        "value" => value
      })
end
