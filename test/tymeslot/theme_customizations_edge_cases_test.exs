defmodule Tymeslot.ThemeCustomizationsEdgeCasesTest do
  use Tymeslot.DataCase, async: true
  @moduletag :themes

  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.{Backgrounds, DataTransform, Defaults}

  # ---- Color validation consistency ----

  describe "color validation consistency between Validation and Capability" do
    test "apply_background_change rejects rgb() color values" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      result =
        ThemeCustomizations.apply_background_change(
          profile.id,
          "1",
          build_customization(profile.id),
          "color",
          "rgb(255,0,0)"
        )

      assert {:error, _reason} = result
    end

    test "apply_background_change rejects named colors" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      result =
        ThemeCustomizations.apply_background_change(
          profile.id,
          "1",
          build_customization(profile.id),
          "color",
          "transparent"
        )

      assert {:error, _reason} = result
    end

    test "apply_background_change rejects 3-digit hex" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      result =
        ThemeCustomizations.apply_background_change(
          profile.id,
          "1",
          build_customization(profile.id),
          "color",
          "#FFF"
        )

      assert {:error, _reason} = result
    end

    test "apply_background_change accepts valid #RRGGBB color" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      result =
        ThemeCustomizations.apply_background_change(
          profile.id,
          "1",
          build_customization(profile.id),
          "color",
          "#FF5500"
        )

      assert {:ok, customization} = result
      assert customization.background_value == "#FF5500"
    end
  end

  # ---- Capability enforcement on write path ----

  describe "capability enforcement" do
    # Note: Both themes "1" and "2" support all background types, so we test
    # that an invalid theme_id is rejected via the capability path.
    test "apply_background_change rejects operation for unknown theme_id" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      customization = build_customization(profile.id)

      result =
        ThemeCustomizations.apply_background_change(
          profile.id,
          "999",
          customization,
          "gradient",
          "gradient_1"
        )

      assert {:error, _reason} = result
    end

    test "apply_color_scheme_change rejects operation for unknown theme_id" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      customization = build_customization(profile.id)

      result =
        ThemeCustomizations.apply_color_scheme_change(profile.id, "999", customization, "purple")

      assert {:error, _reason} = result
    end
  end

  # ---- File cleanup when switching background type ----

  describe "update_theme_customization/2 file cleanup" do
    test "cleans up old image path when switching to gradient (new path is nil)" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      {:ok, customization} =
        ThemeCustomizations.create_theme_customization(profile.id, "1", %{
          "color_scheme" => "default",
          "background_type" => "image",
          "background_value" => "custom",
          "background_image_path" => "themes/#{profile.id}/1/images/old.jpg"
        })

      # Switch to gradient — new image path is nil
      {:ok, updated} =
        ThemeCustomizations.update_theme_customization(customization, %{
          "background_type" => "gradient",
          "background_value" => "gradient_1",
          "background_image_path" => nil
        })

      assert updated.background_image_path == nil
      assert updated.background_type == "gradient"
    end

    test "cleans up old video path when switching to gradient (new path is nil)" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      {:ok, customization} =
        ThemeCustomizations.create_theme_customization(profile.id, "2", %{
          "color_scheme" => "default",
          "background_type" => "video",
          "background_value" => "custom",
          "background_video_path" => "themes/#{profile.id}/2/videos/old.mp4"
        })

      {:ok, updated} =
        ThemeCustomizations.update_theme_customization(customization, %{
          "background_type" => "gradient",
          "background_value" => "gradient_1",
          "background_video_path" => nil
        })

      assert updated.background_video_path == nil
      assert updated.background_type == "gradient"
    end
  end

  # ---- atomize_keys unknown string keys ----

  describe "DataTransform.atomize_keys/1" do
    test "handles unknown string keys without crashing" do
      input = %{"color_scheme" => "default", "unknown_field" => "value", "another_unknown" => 42}

      result = DataTransform.atomize_keys(input)

      assert result[:color_scheme] == "default"
      # Unknown string keys are preserved as strings (not converted to atoms)
      assert result["unknown_field"] == "value"
      assert result["another_unknown"] == 42
    end

    test "converts all known string keys to atoms" do
      input = %{
        "color_scheme" => "purple",
        "background_type" => "gradient",
        "background_value" => "gradient_1",
        "background_image_path" => nil,
        "background_video_path" => nil
      }

      result = DataTransform.atomize_keys(input)

      assert result == %{
               color_scheme: "purple",
               background_type: "gradient",
               background_value: "gradient_1",
               background_image_path: nil,
               background_video_path: nil
             }
    end

    test "preserves atom keys as-is" do
      input = %{color_scheme: "default", background_type: "gradient"}

      result = DataTransform.atomize_keys(input)

      assert result == %{color_scheme: "default", background_type: "gradient"}
    end
  end

  # ---- merge_with_defaults empty string ----

  describe "Defaults.merge_with_defaults/2 empty string handling" do
    test "treats empty string color_scheme as missing, falls back to default" do
      customization = build_customization(1)
      customization = %{customization | color_scheme: ""}

      result = Defaults.merge_with_defaults(customization, "1")

      assert result.color_scheme == "default"
    end

    test "treats empty string background_type as missing, falls back to default" do
      customization = build_customization(1)
      customization = %{customization | background_type: "", background_value: ""}

      result = Defaults.merge_with_defaults(customization, "1")

      assert result.background_type == "gradient"
    end

    test "preserves non-empty values" do
      customization = build_customization(1)

      customization = %{
        customization
        | color_scheme: "purple",
          background_type: "color",
          background_value: "#123456"
      }

      result = Defaults.merge_with_defaults(customization, "1")

      assert result.color_scheme == "purple"
      assert result.background_type == "color"
      assert result.background_value == "#123456"
    end
  end

  # ---- clear_conflicting_backgrounds cross-type paths ----

  describe "Backgrounds.clear_conflicting_backgrounds/2 cross-type path behavior" do
    test "switching to image preset does NOT clear video path (paths are independent)" do
      customization = %{
        background_type: "video",
        background_value: "custom",
        background_image_path: nil,
        background_video_path: "themes/1/1/videos/my.mp4"
      }

      result =
        Backgrounds.clear_conflicting_backgrounds(
          %{customization | background_type: "image", background_value: "preset:some-image"},
          "image"
        )

      # Preset image selection clears image path but NOT video path
      assert result.background_image_path == nil
      assert result.background_video_path == "themes/1/1/videos/my.mp4"
    end

    test "switching to gradient clears both image and video paths" do
      customization = %{
        background_type: "image",
        background_value: "custom",
        background_image_path: "themes/1/1/images/my.jpg",
        background_video_path: "themes/1/1/videos/my.mp4"
      }

      result =
        Backgrounds.clear_conflicting_backgrounds(
          %{customization | background_type: "gradient", background_value: "gradient_1"},
          "gradient"
        )

      assert result.background_image_path == nil
      assert result.background_video_path == nil
    end

    test "switching to color clears both image and video paths" do
      customization = %{
        background_type: "video",
        background_value: "custom",
        background_image_path: "themes/1/1/images/my.jpg",
        background_video_path: "themes/1/1/videos/my.mp4"
      }

      result =
        Backgrounds.clear_conflicting_backgrounds(
          %{customization | background_type: "color", background_value: "#FF0000"},
          "color"
        )

      assert result.background_image_path == nil
      assert result.background_video_path == nil
    end
  end

  # ---- upsert race condition retry ----

  describe "create_theme_customization/3 unique constraint retry" do
    test "falls through to update when customization already exists (simulating race)" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      # Pre-create the customization to simulate a race condition
      {:ok, _existing} =
        ThemeCustomizations.create_theme_customization(profile.id, "1", %{
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
      assert customization.color_scheme == "purple"
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

  # ---- Defaults.theme_supports_feature? no longer hardcoded ----

  describe "Defaults.theme_supports_feature?/2 registry-based" do
    test "returns false for unknown theme_id" do
      refute Defaults.theme_supports_feature?("nonexistent_theme", :video_backgrounds)
    end

    test "returns false for unknown feature" do
      # Known themes still return false for unrecognized feature atoms
      refute Defaults.theme_supports_feature?("1", :some_unknown_feature)
    end
  end

  # Private helper

  defp build_customization(profile_id) do
    %Tymeslot.DatabaseSchemas.ThemeCustomizationSchema{
      profile_id: profile_id,
      theme_id: "1",
      color_scheme: "default",
      background_type: "gradient",
      background_value: "gradient_1",
      background_image_path: nil,
      background_video_path: nil
    }
  end
end
