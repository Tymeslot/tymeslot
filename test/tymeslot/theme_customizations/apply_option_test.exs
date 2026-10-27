defmodule Tymeslot.ThemeCustomizations.ApplyOptionTest do
  use Tymeslot.DataCase, async: false

  @moduletag :themes
  @moduletag :integration

  alias Tymeslot.Test.UploadRoot
  alias Tymeslot.ThemeCustomizations

  @unavailable "This option is not available for this theme."
  @not_saved "Could not save your theme customisation. Please try again."

  setup do
    UploadRoot.isolate("tymeslot_apply_option")

    %{profile: insert(:profile)}
  end

  defp apply(profile, key, field, value, theme_id \\ "1"),
    do:
      ThemeCustomizations.apply_option(profile.id, theme_id, key, %{
        "field" => field,
        "value" => value
      })

  defp stored_image(profile) do
    relative = "themes/#{profile.id}/1/images/old.png"
    full = UploadRoot.path(relative)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "png")
    {relative, full}
  end

  defp stored_video(profile) do
    relative = "themes/#{profile.id}/1/videos/old.mp4"
    full = UploadRoot.path(relative)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "mp4")
    {relative, full}
  end

  describe "palette" do
    test "a scheme is saved and clears a custom seed", %{profile: profile} do
      {:ok, _existing} = apply(profile, :palette, "seed", "#ff6b35")

      assert {:ok, saved} = apply(profile, :palette, "scheme", "forest")
      assert saved.settings["color_scheme"] == "forest"
      assert saved.settings["custom_palette_seed"] == nil
    end

    test "a seed is saved normalised", %{profile: profile} do
      assert {:ok, saved} = apply(profile, :palette, "seed", "#AABBCC")
      assert saved.settings["custom_palette_seed"] == "#aabbcc"
    end

    test "a palette change leaves an uploaded background and its file alone", %{profile: profile} do
      {relative, full} = stored_image(profile)

      {:ok, _existing} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "background_type" => "image",
          "background_value" => "custom",
          "background_image_path" => relative
        })

      assert {:ok, saved} = apply(profile, :palette, "scheme", "ocean")
      assert saved.settings["background_image_path"] == relative
      assert File.exists?(full)
    end
  end

  describe "background" do
    test "a gradient is saved, keeping an uploaded image stored",
         %{profile: profile} do
      {relative, full} = stored_image(profile)

      {:ok, _existing} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "background_type" => "image",
          "background_value" => "custom",
          "background_image_path" => relative
        })

      assert {:ok, saved} = apply(profile, :background, "gradient", "gradient_4")

      assert {saved.settings["background_type"], saved.settings["background_value"]} ==
               {"gradient", "gradient_4"}

      assert saved.settings["background_image_path"] == relative
      assert File.exists?(full)
    end

    test "a preset video is saved, keeping an uploaded image stored",
         %{profile: profile} do
      {relative, full} = stored_image(profile)

      {:ok, _existing} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "background_type" => "image",
          "background_value" => "custom",
          "background_image_path" => relative
        })

      assert {:ok, saved} = apply(profile, :background, "video", "preset:blue-wave")

      assert {saved.settings["background_type"], saved.settings["background_value"]} ==
               {"video", "preset:blue-wave"}

      assert saved.settings["background_image_path"] == relative
      assert File.exists?(full)
    end

    test "a preset image is saved, keeping an uploaded video stored",
         %{profile: profile} do
      {relative, full} = stored_video(profile)

      {:ok, _existing} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "background_type" => "video",
          "background_value" => "custom",
          "background_video_path" => relative
        })

      assert {:ok, saved} = apply(profile, :background, "image", "preset:artistic-studio")

      assert {saved.settings["background_type"], saved.settings["background_value"]} ==
               {"image", "preset:artistic-studio"}

      assert saved.settings["background_video_path"] == relative
      assert File.exists?(full)
    end

    test "switching back to an upload shows it again without a new upload",
         %{profile: profile} do
      {relative, full} = stored_image(profile)

      {:ok, _existing} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "background_type" => "gradient",
          "background_value" => "gradient_1",
          "background_image_path" => relative
        })

      assert {:ok, saved} = apply(profile, :background, "image", "custom")

      assert {saved.settings["background_type"], saved.settings["background_value"],
              saved.settings["background_image_path"]} == {"image", "custom", relative}

      assert File.exists?(full)
    end

    test "switching to an upload that is not stored is refused", %{profile: profile} do
      {:ok, _existing} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{})

      assert {:error, @not_saved} = apply(profile, :background, "video", "custom")

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1").settings[
               "background_type"
             ] == "gradient"
    end

    test "removing the upload on show deletes it and shows the theme's default background",
         %{profile: profile} do
      {image, image_file} = stored_image(profile)
      {video, video_file} = stored_video(profile)

      {:ok, _existing} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "background_type" => "video",
          "background_value" => "custom",
          "background_image_path" => image,
          "background_video_path" => video
        })

      assert {:ok, saved} = apply(profile, :background, "remove", "video")

      assert Map.take(saved.settings, ~w(background_type background_value background_video_path
                                          background_image_path)) == %{
               "background_type" => "gradient",
               "background_value" => "gradient_1",
               "background_image_path" => image
             }

      refute File.exists?(video_file)
      assert File.exists?(image_file)
    end

    test "removing an upload not on show deletes only it", %{profile: profile} do
      {image, image_file} = stored_image(profile)

      {:ok, _existing} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "background_type" => "gradient",
          "background_value" => "gradient_4",
          "background_image_path" => image
        })

      assert {:ok, saved} = apply(profile, :background, "remove", "image")

      assert {saved.settings["background_type"], saved.settings["background_value"],
              saved.settings["background_image_path"]} == {"gradient", "gradient_4", nil}

      refute File.exists?(image_file)
    end

    test "removing an upload of a kind the theme does not offer is refused", %{profile: profile} do
      assert {:error, @unavailable} = apply(profile, :background, "remove", "pattern")
    end

    test "a kind the theme does not declare is refused", %{profile: profile} do
      assert {:error, @unavailable} = apply(profile, :background, "pattern", "stripes")
      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1") == nil
    end

    test "an unknown preset is refused by the changeset", %{profile: profile} do
      assert {:error, @not_saved} = apply(profile, :background, "gradient", "gradient_999")
      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1") == nil
    end
  end

  describe "a stored row the spec no longer fully accepts" do
    test "saves another group, and gives the stale group its default", %{profile: profile} do
      insert(:theme_customization,
        profile: profile,
        theme_id: "1",
        settings: %{
          "color_scheme" => "default",
          "background_type" => "gradient",
          "background_value" => "gradient_99"
        }
      )

      assert {:ok, saved} = apply(profile, :palette, "scheme", "forest")
      assert saved.settings["color_scheme"] == "forest"

      assert {saved.settings["background_type"], saved.settings["background_value"]} ==
               {"gradient", "gradient_1"}
    end

    test "saves a row stored before the spec had a group, which starts from its default",
         %{profile: profile} do
      insert(:theme_customization,
        profile: profile,
        theme_id: "1",
        settings: %{"color_scheme" => "ocean"}
      )

      assert {:ok, saved} = apply(profile, :palette, "scheme", "forest")
      assert saved.settings["color_scheme"] == "forest"
      assert saved.settings["background_type"] == "gradient"
    end

    test "still refuses a change the group does not accept", %{profile: profile} do
      insert(:theme_customization,
        profile: profile,
        theme_id: "1",
        settings: %{
          "color_scheme" => "default",
          "background_type" => "gradient",
          "background_value" => "gradient_99"
        }
      )

      assert {:error, @not_saved} = apply(profile, :background, "gradient", "gradient_999")
    end
  end

  describe "refusals" do
    test "an option the theme does not declare", %{profile: profile} do
      assert {:error, @unavailable} = apply(profile, :logo, "file", "x.png")
    end

    test "an unknown theme", %{profile: profile} do
      assert {:error, @unavailable} = apply(profile, :palette, "scheme", "forest", "999")
    end

    test "a malformed payload", %{profile: profile} do
      assert {:error, @unavailable} =
               ThemeCustomizations.apply_option(profile.id, "1", :palette, %{"field" => "scheme"})
    end
  end
end
