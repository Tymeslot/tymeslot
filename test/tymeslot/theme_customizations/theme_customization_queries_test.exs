defmodule Tymeslot.ThemeCustomizations.ThemeCustomizationQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.ThemeCustomizations.ThemeCustomizationQueries

  describe "create/1" do
    test "creates a theme customization with valid attributes" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        theme_id: "1",
        color_scheme: "default",
        background_type: "gradient",
        background_value: "gradient_1"
      }

      assert {:ok, customization} = ThemeCustomizationQueries.create(attrs)
      assert customization.profile_id == profile.id
      assert customization.theme_id == "1"
      assert customization.settings["color_scheme"] == "default"
      assert customization.settings["background_type"] == "gradient"
      assert customization.settings["background_value"] == "gradient_1"
    end

    test "persists gradient and colour backgrounds with their own value formats" do
      profile = insert(:profile)

      assert {:ok, gradient} =
               ThemeCustomizationQueries.create(%{
                 profile_id: profile.id,
                 theme_id: "1",
                 color_scheme: "default",
                 background_type: "gradient",
                 background_value: "gradient_1"
               })

      assert {:ok, color} =
               ThemeCustomizationQueries.create(%{
                 profile_id: profile.id,
                 theme_id: "2",
                 color_scheme: "turquoise",
                 background_type: "color",
                 background_value: "#06b6d4"
               })

      assert gradient.settings["background_type"] == "gradient"
      assert gradient.settings["background_value"] == "gradient_1"
      assert color.settings["background_type"] == "color"
      assert color.settings["background_value"] == "#06b6d4"

      # Both survive the round trip; neither overwrites the other's row.
      assert %{settings: %{"background_type" => "gradient", "background_value" => "gradient_1"}} =
               ThemeCustomizationQueries.get_by_profile_and_theme(profile.id, "1")

      assert %{settings: %{"background_type" => "color", "background_value" => "#06b6d4"}} =
               ThemeCustomizationQueries.get_by_profile_and_theme(profile.id, "2")
    end

    test "writes nothing when the profile already has a customization of the theme" do
      profile = insert(:profile)

      existing = insert(:theme_customization, profile: profile, theme_id: "1")

      assert {:ok, :exists} =
               ThemeCustomizationQueries.create(%{
                 profile_id: profile.id,
                 theme_id: "1",
                 color_scheme: "purple",
                 background_type: "gradient",
                 background_value: "gradient_1"
               })

      assert ThemeCustomizationQueries.get_by_profile_and_theme(profile.id, "1").settings ==
               existing.settings
    end

    test "allows same theme customization for different profiles" do
      profile1 = insert(:profile)
      profile2 = insert(:profile)

      insert(:theme_customization, profile: profile1, theme_id: "1")

      {:ok, customization} =
        ThemeCustomizationQueries.create(%{
          profile_id: profile2.id,
          theme_id: "1",
          color_scheme: "default",
          background_type: "gradient",
          background_value: "gradient_1"
        })

      assert customization.profile_id == profile2.id
    end
  end

  describe "get_by_profile_and_theme/2" do
    test "retrieves customization by profile and theme" do
      profile = insert(:profile)

      customization =
        insert(:theme_customization, profile: profile, theme_id: "1", color_scheme: "purple")

      result = ThemeCustomizationQueries.get_by_profile_and_theme(profile.id, "1")

      assert result.id == customization.id
      assert result.settings["color_scheme"] == "purple"
    end

    test "returns nil when customization does not exist" do
      profile = insert(:profile)

      result = ThemeCustomizationQueries.get_by_profile_and_theme(profile.id, "nonexistent")

      assert result == nil
    end
  end

  describe "update/2" do
    test "updates customization attributes" do
      customization =
        insert(:theme_customization, color_scheme: "default", background_type: "gradient")

      attrs = %{color_scheme: "purple", background_type: "color", background_value: "#8b5cf6"}

      assert {:ok, updated} = ThemeCustomizationQueries.update(customization, attrs)
      assert updated.settings["color_scheme"] == "purple"
      assert updated.settings["background_type"] == "color"
      assert updated.settings["background_value"] == "#8b5cf6"
      assert updated.id == customization.id
    end

    test "validates updated attributes" do
      customization = insert(:theme_customization)

      attrs = %{color_scheme: "invalid_scheme"}

      assert {:error, changeset} = ThemeCustomizationQueries.update(customization, attrs)
      assert "is invalid" in errors_on(changeset).color_scheme
    end
  end

  describe "update_video_processing_status/3" do
    test "answers not found for a customisation that no longer exists" do
      profile = insert(:profile)
      customization = insert(:theme_customization, profile: profile)
      Repo.delete!(customization)

      assert ThemeCustomizationQueries.update_video_processing_status(
               customization.id,
               "background_video_path",
               "completed"
             ) == {:error, :not_found}
    end
  end

  describe "get_profile_by_user_id/1" do
    test "retrieves profile by user_id" do
      user = insert(:user)
      profile = insert(:profile, user: user)

      result = ThemeCustomizationQueries.get_profile_by_user_id(user.id)

      assert result.id == profile.id
      assert result.user_id == user.id
    end

    test "returns nil when user has no profile" do
      result = ThemeCustomizationQueries.get_profile_by_user_id(999_999)

      assert result == nil
    end
  end

  describe "background type validations" do
    test "accepts valid gradient preset" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        theme_id: "1",
        color_scheme: "default",
        background_type: "gradient",
        background_value: "gradient_1"
      }

      assert {:ok, customization} = ThemeCustomizationQueries.create(attrs)
      assert customization.settings["background_type"] == "gradient"
      assert customization.settings["background_value"] == "gradient_1"
    end

    test "rejects invalid gradient preset" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        theme_id: "1",
        color_scheme: "default",
        background_type: "gradient",
        background_value: "invalid_gradient"
      }

      assert {:error, changeset} = ThemeCustomizationQueries.create(attrs)
      assert "must be a valid gradient preset" in errors_on(changeset).background_value
    end

    test "accepts valid hex color" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        theme_id: "1",
        color_scheme: "default",
        background_type: "color",
        background_value: "#06b6d4"
      }

      assert {:ok, customization} = ThemeCustomizationQueries.create(attrs)
      assert customization.settings["background_value"] == "#06b6d4"
    end

    test "rejects invalid hex color format" do
      profile = insert(:profile)

      test_cases = [
        "06b6d4",
        "#06b6d",
        "#06b6d4ff",
        "rgb(6, 182, 212)",
        "not-a-color"
      ]

      for invalid_color <- test_cases do
        attrs = %{
          profile_id: profile.id,
          theme_id: "1",
          color_scheme: "default",
          background_type: "color",
          background_value: invalid_color
        }

        assert {:error, changeset} = ThemeCustomizationQueries.create(attrs)
        assert "must be a hex colour such as #14b8a6" in errors_on(changeset).background_value
      end
    end

    test "accepts preset image without image path" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        theme_id: "1",
        color_scheme: "default",
        background_type: "image",
        background_value: "preset:artistic-studio"
      }

      assert {:ok, customization} = ThemeCustomizationQueries.create(attrs)
      assert customization.settings["background_value"] == "preset:artistic-studio"
    end

    test "accepts uploaded image with image path" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        theme_id: "1",
        color_scheme: "default",
        background_type: "image",
        background_value: "uploaded",
        background_image_path: "/uploads/image.jpg"
      }

      assert {:ok, customization} = ThemeCustomizationQueries.create(attrs)
      assert customization.settings["background_image_path"] == "/uploads/image.jpg"
    end

    test "rejects uploaded image without image path" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        theme_id: "1",
        color_scheme: "default",
        background_type: "image",
        background_value: "uploaded"
      }

      assert {:error, changeset} = ThemeCustomizationQueries.create(attrs)

      assert "is required for an uploaded image background" in errors_on(changeset).background_image_path
    end

    test "accepts preset video without video path" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        theme_id: "2",
        color_scheme: "default",
        background_type: "video",
        background_value: "preset:rhythm-default"
      }

      assert {:ok, customization} = ThemeCustomizationQueries.create(attrs)
      assert customization.settings["background_value"] == "preset:rhythm-default"
    end

    test "accepts uploaded video with video path" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        theme_id: "2",
        color_scheme: "default",
        background_type: "video",
        background_value: "uploaded",
        background_video_path: "/uploads/video.mp4"
      }

      assert {:ok, customization} = ThemeCustomizationQueries.create(attrs)
      assert customization.settings["background_video_path"] == "/uploads/video.mp4"
    end

    test "rejects uploaded video without video path" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        theme_id: "2",
        color_scheme: "default",
        background_type: "video",
        background_value: "uploaded"
      }

      assert {:error, changeset} = ThemeCustomizationQueries.create(attrs)

      assert "is required for an uploaded video background" in errors_on(changeset).background_video_path
    end
  end

  describe "color scheme validations" do
    test "accepts all valid color schemes" do
      valid_schemes = [
        "default",
        "turquoise",
        "purple",
        "sunset",
        "ocean",
        "forest",
        "rose",
        "monochrome"
      ]

      for color_scheme <- valid_schemes do
        # Create a new profile for each test to avoid unique constraint violations
        profile = insert(:profile)

        attrs = %{
          profile_id: profile.id,
          theme_id: "1",
          color_scheme: color_scheme,
          background_type: "gradient",
          background_value: "gradient_1"
        }

        assert {:ok, _created_customization} = ThemeCustomizationQueries.create(attrs)
      end
    end

    test "rejects invalid color scheme" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        theme_id: "1",
        color_scheme: "invalid_scheme",
        background_type: "gradient",
        background_value: "gradient_1"
      }

      assert {:error, changeset} = ThemeCustomizationQueries.create(attrs)
      assert "is invalid" in errors_on(changeset).color_scheme
    end
  end
end
