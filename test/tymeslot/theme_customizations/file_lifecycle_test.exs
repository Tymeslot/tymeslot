defmodule Tymeslot.ThemeCustomizations.FileLifecycleTest do
  @moduledoc """
  Exercises the background-asset cleanup orchestration through the public
  context API. Each test stores real files under a temporary upload root and
  asserts on filesystem state after update/delete, since the orchestration's
  whole purpose is to remove stale files (and transcoded video variants) once
  the database write succeeds.
  """
  use Tymeslot.DataCase, async: false
  @moduletag :utils

  alias Tymeslot.Media.Transcoder
  alias Tymeslot.Profiles
  alias Tymeslot.Test.ShowcaseThemeSpec
  alias Tymeslot.Test.UploadRoot
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.FileLifecycle
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationQueries
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  setup do
    upload_root = UploadRoot.isolate("tymeslot_uploads")

    user = insert(:user)
    {:ok, profile} = Profiles.get_or_create_profile(user.id)

    %{upload_root: upload_root, profile: profile}
  end

  # Writes a file at the given stored relative path and returns its absolute path.
  defp touch_stored(relative_path) do
    absolute = UploadRoot.path(relative_path)
    File.mkdir_p!(Path.dirname(absolute))
    File.write!(absolute, "data")
    absolute
  end

  # The showcase theme's spec declares every shared group, three of them
  # (logo, cover, background) with an image upload. Its rows are built in
  # memory and the spec is passed in, so each test controls exactly which
  # files a row names.
  defp logo_row(profile, settings),
    do: %ThemeCustomizationSchema{profile_id: profile.id, theme_id: "97", settings: settings}

  defp with_settings(row, changes), do: %{row | settings: Map.merge(row.settings, changes)}

  describe "upsert_theme_customization/3 file cleanup" do
    test "deletes the old image when the image path is replaced", %{profile: profile} do
      old_rel = "themes/#{profile.id}/1/images/old.jpg"
      old_abs = touch_stored(old_rel)
      new_rel = "themes/#{profile.id}/1/images/new.jpg"
      new_abs = touch_stored(new_rel)

      {:ok, customization} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "color_scheme" => "default",
          "background_type" => "image",
          "background_value" => "uploaded",
          "background_image_path" => old_rel
        })

      assert {:ok, _updated} =
               ThemeCustomizations.upsert_theme_customization(
                 customization.profile_id,
                 customization.theme_id,
                 %{
                   "background_image_path" => new_rel
                 }
               )

      refute File.exists?(old_abs)
      assert File.exists?(new_abs)
    end

    test "keeps the image when the path is unchanged", %{profile: profile} do
      rel = "themes/#{profile.id}/1/images/keep.jpg"
      abs = touch_stored(rel)

      {:ok, customization} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "color_scheme" => "default",
          "background_type" => "image",
          "background_value" => "uploaded",
          "background_image_path" => rel
        })

      assert {:ok, _updated} =
               ThemeCustomizations.upsert_theme_customization(
                 customization.profile_id,
                 customization.theme_id,
                 %{
                   "background_image_path" => rel,
                   "color_scheme" => "ocean"
                 }
               )

      assert File.exists?(abs)
    end

    test "deletes the old video and its transcoded variants when replaced", %{profile: profile} do
      old_rel = "themes/#{profile.id}/1/videos/old.mp4"
      old_abs = touch_stored(old_rel)
      variant_abs = old_rel |> Transcoder.derive_variant_paths() |> Enum.map(&touch_stored/1)

      new_rel = "themes/#{profile.id}/1/videos/new.mp4"
      new_abs = touch_stored(new_rel)

      {:ok, customization} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "color_scheme" => "default",
          "background_type" => "video",
          "background_value" => "uploaded",
          "background_video_path" => old_rel
        })

      assert {:ok, _updated} =
               ThemeCustomizations.upsert_theme_customization(
                 customization.profile_id,
                 customization.theme_id,
                 %{
                   "background_video_path" => new_rel
                 }
               )

      refute File.exists?(old_abs)
      Enum.each(variant_abs, fn path -> refute File.exists?(path) end)
      assert File.exists?(new_abs)
    end

    test "keeps the stored video when its processing state is recorded", %{profile: profile} do
      rel = "themes/#{profile.id}/1/videos/upload.mp4"
      abs = touch_stored(rel)

      {:ok, customization} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "color_scheme" => "default",
          "background_type" => "video",
          "background_value" => "custom",
          "background_video_path" => rel
        })

      assert {:ok, _recorded} =
               ThemeCustomizationQueries.update_video_processing_status(
                 customization.id,
                 "background_video_path",
                 "failed"
               )

      reloaded = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
      assert reloaded.settings["background_video_path"] == rel
      assert reloaded.video_processing_status == %{"background_video_path" => "failed"}
      assert File.exists?(abs)
    end

    test "keeps the image when an update does not touch its path", %{profile: profile} do
      rel = "themes/#{profile.id}/1/images/keep.jpg"
      abs = touch_stored(rel)

      {:ok, customization} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "color_scheme" => "default",
          "background_type" => "image",
          "background_value" => "custom",
          "background_image_path" => rel
        })

      assert {:ok, _updated} =
               ThemeCustomizations.upsert_theme_customization(
                 customization.profile_id,
                 customization.theme_id,
                 %{
                   "color_scheme" => "ocean"
                 }
               )

      assert File.exists?(abs)
    end
  end

  describe "partial updates keep the files the row still references" do
    setup %{profile: profile} do
      image_rel = "themes/#{profile.id}/1/images/kept.jpg"
      video_rel = "themes/#{profile.id}/1/videos/kept.mp4"

      {:ok, customization} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "background_type" => "video",
          "background_value" => "custom",
          "background_image_path" => image_rel,
          "background_video_path" => video_rel
        })

      %{
        customization: customization,
        image_rel: image_rel,
        video_rel: video_rel,
        image_abs: touch_stored(image_rel),
        video_abs: touch_stored(video_rel),
        variant_abs: video_rel |> Transcoder.derive_variant_paths() |> Enum.map(&touch_stored/1)
      }
    end

    test "an update that leaves both paths out keeps both files and the video's variants",
         ctx do
      assert {:ok, updated} =
               ThemeCustomizations.upsert_theme_customization(
                 ctx.customization.profile_id,
                 ctx.customization.theme_id,
                 %{
                   "background_type" => "image",
                   "background_value" => "custom"
                 }
               )

      assert updated.settings["background_image_path"] == ctx.image_rel
      assert updated.settings["background_video_path"] == ctx.video_rel
      assert File.exists?(ctx.image_abs)
      assert File.exists?(ctx.video_abs)
      assert Enum.all?(ctx.variant_abs, &File.exists?/1)
    end

    test "an explicit nil clears the path and deletes its file", ctx do
      assert {:ok, updated} =
               ThemeCustomizations.upsert_theme_customization(
                 ctx.customization.profile_id,
                 ctx.customization.theme_id,
                 %{
                   "background_image_path" => nil
                 }
               )

      assert updated.settings["background_image_path"] == nil
      refute File.exists?(ctx.image_abs)
      assert File.exists?(ctx.video_abs)
    end

    test "choosing a gradient keeps both uploads and their files", ctx do
      assert {:ok, updated} =
               ThemeCustomizations.apply_option(ctx.profile.id, "1", :background, %{
                 "field" => "gradient",
                 "value" => "gradient_2"
               })

      assert updated.settings["background_type"] == "gradient"

      assert {updated.settings["background_image_path"],
              updated.settings["background_video_path"]} == {ctx.image_rel, ctx.video_rel}

      assert File.exists?(ctx.image_abs)
      assert File.exists?(ctx.video_abs)
      assert Enum.all?(ctx.variant_abs, &File.exists?/1)
    end
  end

  describe "asset fields of any option group" do
    setup %{profile: profile} do
      background = "themes/#{profile.id}/1/images/a-bg.png"
      logo = "themes/#{profile.id}/1/images/b-logo.png"

      row =
        logo_row(profile, %{
          "color_scheme" => "neutral",
          "background_type" => "image",
          "background_value" => "custom",
          "background_image_path" => background,
          "logo_path" => logo
        })

      %{row: row, background: touch_stored(background), logo: touch_stored(logo)}
    end

    test "replacing the logo deletes the old logo and leaves the background's file",
         %{row: row, background: background, logo: logo, profile: profile} do
      new_logo = touch_stored("themes/#{profile.id}/1/images/c-logo.png")
      updated = with_settings(row, %{"logo_path" => "themes/#{profile.id}/1/images/c-logo.png"})

      FileLifecycle.cleanup_replaced_files(ShowcaseThemeSpec, row, updated)

      refute File.exists?(logo)
      assert File.exists?(new_logo)
      assert File.exists?(background)
    end

    test "clearing the logo deletes its file only", %{
      row: row,
      background: background,
      logo: logo
    } do
      FileLifecycle.cleanup_replaced_files(
        ShowcaseThemeSpec,
        row,
        with_settings(row, %{"logo_path" => nil})
      )

      refute File.exists?(logo)
      assert File.exists?(background)
    end

    test "replacing the background leaves the logo's file",
         %{row: row, background: background, logo: logo} do
      updated =
        with_settings(row, %{"background_type" => "gradient", "background_image_path" => nil})

      FileLifecycle.cleanup_replaced_files(ShowcaseThemeSpec, row, updated)

      refute File.exists?(background)
      assert File.exists?(logo)
    end
  end
end
