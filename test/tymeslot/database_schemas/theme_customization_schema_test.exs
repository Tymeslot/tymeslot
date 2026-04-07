defmodule Tymeslot.ThemeCustomizations.ThemeCustomizationSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :schema

  alias Tymeslot.Repo
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

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

    test "gradient background with nil background_value is invalid" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        theme_id: "1",
        color_scheme: "default",
        background_type: "gradient",
        background_value: nil
      }

      changeset = ThemeCustomizationSchema.changeset(%ThemeCustomizationSchema{}, attrs)

      refute changeset.valid?
      assert errors_on(changeset).background_value != []
    end

    test "color background with nil background_value is invalid" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        theme_id: "1",
        color_scheme: "default",
        background_type: "color",
        background_value: nil
      }

      changeset = ThemeCustomizationSchema.changeset(%ThemeCustomizationSchema{}, attrs)

      refute changeset.valid?
      assert errors_on(changeset).background_value != []
    end
  end

  describe "unique constraint format" do
    test "duplicate profile_id + theme_id produces a unique constraint changeset error" do
      profile = insert(:profile)

      attrs = %{
        profile_id: profile.id,
        theme_id: "1",
        color_scheme: "default",
        background_type: "gradient",
        background_value: "gradient_1"
      }

      {:ok, _first} =
        %ThemeCustomizationSchema{}
        |> ThemeCustomizationSchema.changeset(attrs)
        |> Repo.insert()

      {:error, changeset} =
        %ThemeCustomizationSchema{}
        |> ThemeCustomizationSchema.changeset(attrs)
        |> Repo.insert()

      # The error must be on :profile_id with constraint: :unique so that
      # ThemeCustomizations.create_theme_customization/3 can detect and recover from it
      assert Enum.any?(changeset.errors, fn {field, {_msg, opts}} ->
               field == :profile_id and Keyword.get(opts, :constraint) == :unique
             end)
    end
  end
end
