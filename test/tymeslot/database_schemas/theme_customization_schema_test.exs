defmodule Tymeslot.DatabaseSchemas.ThemeCustomizationSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :schema

  alias Tymeslot.DatabaseSchemas.ThemeCustomizationSchema

  describe "background validation business rules" do
    test "uploaded video backgrounds require video path" do
      profile = insert(:profile)

      # Custom video without path - should fail
      attrs = %{
        profile_id: profile.id,
        # Rhythm theme ID
        theme_id: "2",
        color_scheme: "default",
        background_type: "video",
        # Not a preset
        background_value: "custom"
      }

      changeset = ThemeCustomizationSchema.changeset(%ThemeCustomizationSchema{}, attrs)

      refute changeset.valid?

      assert "is required for uploaded video background" in errors_on(changeset).background_video_path
    end

    test "uploaded image backgrounds require image path" do
      profile = insert(:profile)

      # Custom image without path - should fail
      attrs = %{
        profile_id: profile.id,
        # Rhythm theme ID
        theme_id: "2",
        color_scheme: "default",
        background_type: "image",
        # Not a preset
        background_value: "custom"
      }

      changeset = ThemeCustomizationSchema.changeset(%ThemeCustomizationSchema{}, attrs)

      refute changeset.valid?

      assert "is required for uploaded image background" in errors_on(changeset).background_image_path
    end

    test "preset backgrounds work without upload paths" do
      profile = insert(:profile)

      # Preset video - should succeed without path
      attrs = %{
        profile_id: profile.id,
        # Rhythm theme ID
        theme_id: "2",
        color_scheme: "default",
        background_type: "video",
        background_value: "preset:rhythm-default"
      }

      changeset = ThemeCustomizationSchema.changeset(%ThemeCustomizationSchema{}, attrs)

      assert changeset.valid?
    end
  end
end
