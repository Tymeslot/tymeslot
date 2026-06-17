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
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Storage

  setup do
    upload_root =
      Path.join(System.tmp_dir!(), "tymeslot_uploads_#{System.unique_integer([:positive])}")

    original_root = Application.get_env(:tymeslot, :upload_directory)
    Application.put_env(:tymeslot, :upload_directory, upload_root)

    on_exit(fn ->
      Application.put_env(:tymeslot, :upload_directory, original_root)
      File.rm_rf(upload_root)
    end)

    user = insert(:user)
    {:ok, profile} = Profiles.get_or_create_profile(user.id)

    %{upload_root: upload_root, profile: profile}
  end

  # Writes a file at the given stored relative path and returns its absolute path.
  defp touch_stored(relative_path) do
    absolute = Storage.build_theme_file_path(relative_path)
    File.mkdir_p!(Path.dirname(absolute))
    File.write!(absolute, "data")
    absolute
  end

  describe "update_theme_customization/2 file cleanup" do
    test "deletes the old image when the image path is replaced", %{profile: profile} do
      old_rel = "themes/#{profile.id}/1/images/old.jpg"
      old_abs = touch_stored(old_rel)
      new_rel = "themes/#{profile.id}/1/images/new.jpg"
      new_abs = touch_stored(new_rel)

      {:ok, customization} =
        ThemeCustomizations.create_theme_customization(profile.id, "1", %{
          "background_type" => "image",
          "background_value" => "uploaded",
          "background_image_path" => old_rel
        })

      assert {:ok, _updated} =
               ThemeCustomizations.update_theme_customization(customization, %{
                 "background_image_path" => new_rel
               })

      refute File.exists?(old_abs)
      assert File.exists?(new_abs)
    end

    test "keeps the image when the path is unchanged", %{profile: profile} do
      rel = "themes/#{profile.id}/1/images/keep.jpg"
      abs = touch_stored(rel)

      {:ok, customization} =
        ThemeCustomizations.create_theme_customization(profile.id, "1", %{
          "background_type" => "image",
          "background_value" => "uploaded",
          "background_image_path" => rel
        })

      assert {:ok, _updated} =
               ThemeCustomizations.update_theme_customization(customization, %{
                 "background_image_path" => rel,
                 "color_scheme" => "ocean"
               })

      assert File.exists?(abs)
    end

    test "deletes the old video and its transcoded variants when replaced", %{profile: profile} do
      old_rel = "themes/#{profile.id}/1/videos/old.mp4"
      old_abs = touch_stored(old_rel)
      variant_abs = old_rel |> Transcoder.derive_variant_paths() |> Enum.map(&touch_stored/1)

      new_rel = "themes/#{profile.id}/1/videos/new.mp4"
      new_abs = touch_stored(new_rel)

      {:ok, customization} =
        ThemeCustomizations.create_theme_customization(profile.id, "1", %{
          "background_type" => "video",
          "background_value" => "uploaded",
          "background_video_path" => old_rel
        })

      assert {:ok, _updated} =
               ThemeCustomizations.update_theme_customization(customization, %{
                 "background_video_path" => new_rel
               })

      refute File.exists?(old_abs)
      Enum.each(variant_abs, fn path -> refute File.exists?(path) end)
      assert File.exists?(new_abs)
    end
  end

  describe "delete_theme_customization/1 file cleanup" do
    test "removes the image file on delete", %{profile: profile} do
      rel = "themes/#{profile.id}/1/images/bg.jpg"
      abs = touch_stored(rel)

      {:ok, customization} =
        ThemeCustomizations.create_theme_customization(profile.id, "1", %{
          "background_type" => "image",
          "background_value" => "uploaded",
          "background_image_path" => rel
        })

      assert {:ok, _deleted} = ThemeCustomizations.delete_theme_customization(customization)
      refute File.exists?(abs)
    end

    test "removes the video file and its transcoded variants on delete", %{profile: profile} do
      rel = "themes/#{profile.id}/1/videos/bg.mp4"
      abs = touch_stored(rel)
      variant_abs = rel |> Transcoder.derive_variant_paths() |> Enum.map(&touch_stored/1)

      {:ok, customization} =
        ThemeCustomizations.create_theme_customization(profile.id, "1", %{
          "background_type" => "video",
          "background_value" => "uploaded",
          "background_video_path" => rel
        })

      assert {:ok, _deleted} = ThemeCustomizations.delete_theme_customization(customization)

      refute File.exists?(abs)
      Enum.each(variant_abs, fn path -> refute File.exists?(path) end)
    end
  end
end
