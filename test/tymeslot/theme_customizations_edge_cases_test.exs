defmodule Tymeslot.ThemeCustomizationsEdgeCasesTest do
  use Tymeslot.DataCase, async: true
  @moduletag :themes

  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.ThemeCustomizations

  @not_saved "Could not save your theme customisation. Please try again."
  @unavailable "This option is not available for this theme."

  # ---- Color validation consistency ----

  describe "background colour validation" do
    test "apply_option rejects rgb() color values" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      result =
        ThemeCustomizations.apply_option(profile.id, "1", :background, %{
          "field" => "color",
          "value" => "rgb(255,0,0)"
        })

      assert {:error, @not_saved} = result
    end

    test "apply_option rejects named colors" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      result =
        ThemeCustomizations.apply_option(profile.id, "1", :background, %{
          "field" => "color",
          "value" => "transparent"
        })

      assert {:error, @not_saved} = result
    end

    test "apply_option saves a 3-digit hex as lower-case #rrggbb" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      assert {:ok, customization} =
               ThemeCustomizations.apply_option(profile.id, "1", :background, %{
                 "field" => "color",
                 "value" => "#FFF"
               })

      assert customization.settings["background_value"] == "#ffffff"

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1").settings[
               "background_value"
             ] == "#ffffff"
    end

    test "apply_option rejects the #RRGGBBAA alpha form" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      assert {:error, @not_saved} =
               ThemeCustomizations.apply_option(profile.id, "1", :background, %{
                 "field" => "color",
                 "value" => "#ff550080"
               })
    end

    test "apply_option accepts valid #RRGGBB color" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      result =
        ThemeCustomizations.apply_option(profile.id, "1", :background, %{
          "field" => "color",
          "value" => "#FF5500"
        })

      assert {:ok, customization} = result
      assert customization.settings["background_value"] == "#ff5500"
    end
  end

  # ---- Unknown theme on the write path ----

  describe "unknown theme" do
    test "apply_option rejects a background change for an unknown theme_id" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      result =
        ThemeCustomizations.apply_option(profile.id, "999", :background, %{
          "field" => "gradient",
          "value" => "gradient_1"
        })

      assert {:error, @unavailable} = result
    end

    test "apply_option rejects a scheme change for an unknown theme_id" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      result =
        ThemeCustomizations.apply_option(profile.id, "999", :palette, %{
          "field" => "scheme",
          "value" => "purple"
        })

      assert {:error, @unavailable} = result
    end
  end

  # ---- File cleanup when switching background type ----

  describe "upsert_theme_customization/3 file cleanup" do
    test "cleans up old image path when switching to gradient (new path is nil)" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      {:ok, customization} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "color_scheme" => "default",
          "background_type" => "image",
          "background_value" => "custom",
          "background_image_path" => "themes/#{profile.id}/1/images/old.jpg"
        })

      # Switch to gradient — new image path is nil
      {:ok, updated} =
        ThemeCustomizations.upsert_theme_customization(
          customization.profile_id,
          customization.theme_id,
          %{
            "background_type" => "gradient",
            "background_value" => "gradient_1",
            "background_image_path" => nil
          }
        )

      assert updated.settings["background_image_path"] == nil
      assert updated.settings["background_type"] == "gradient"
    end

    test "cleans up old video path when switching to gradient (new path is nil)" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      {:ok, customization} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "2", %{
          "color_scheme" => "default",
          "background_type" => "video",
          "background_value" => "custom",
          "background_video_path" => "themes/#{profile.id}/2/videos/old.mp4"
        })

      {:ok, updated} =
        ThemeCustomizations.upsert_theme_customization(
          customization.profile_id,
          customization.theme_id,
          %{
            "background_type" => "gradient",
            "background_value" => "gradient_1",
            "background_video_path" => nil
          }
        )

      assert updated.settings["background_video_path"] == nil
      assert updated.settings["background_type"] == "gradient"
    end
  end

  # ---- upsert race condition retry ----

  describe "upsert_theme_customization/3 unique constraint retry" do
    test "falls through to update when customization already exists (simulating race)" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      # Pre-create the customization to simulate a race condition
      {:ok, _existing} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "color_scheme" => "default",
          "background_type" => "gradient",
          "background_value" => "gradient_1"
        })

      # Now call upsert — should not error, should update the existing record
      result =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "color_scheme" => "purple"
        })

      assert {:ok, customization} = result
      assert customization.settings["color_scheme"] == "purple"
    end

    test "upsert is idempotent when called multiple times" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      attrs = %{
        "color_scheme" => "turquoise",
        "background_type" => "gradient",
        "background_value" => "gradient_1"
      }

      {:ok, first} = ThemeCustomizations.upsert_theme_customization(profile.id, "1", attrs)
      {:ok, second} = ThemeCustomizations.upsert_theme_customization(profile.id, "1", attrs)

      assert first.id == second.id
    end
  end

  # ---- Cascade delete ----

  describe "cascade delete when profile is deleted" do
    test "customizations are removed from DB when profile is deleted" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      {:ok, customization} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "color_scheme" => "default",
          "background_type" => "gradient",
          "background_value" => "gradient_1"
        })

      # The customization exists before deletion
      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1").id == customization.id

      # Delete the profile — cascade should remove customizations
      Repo.delete!(profile)

      # Customization must no longer exist
      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1") == nil
    end
  end
end
