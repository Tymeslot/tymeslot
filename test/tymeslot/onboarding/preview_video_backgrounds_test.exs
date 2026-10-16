defmodule Tymeslot.Onboarding.PreviewVideoBackgroundsTest do
  @moduledoc """
  Onboarding's preview video is a background choice like any other: saved
  through the background option group, it drops the upload it replaces and
  deletes its file, and leaves the rest of the customisation alone.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :onboarding
  @moduletag :themes

  alias Tymeslot.Onboarding
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Storage

  setup do
    upload_root =
      Path.join(System.tmp_dir!(), "tymeslot_preview_video_#{System.unique_integer([:positive])}")

    original_root = Application.get_env(:tymeslot, :upload_directory)
    Application.put_env(:tymeslot, :upload_directory, upload_root)

    on_exit(fn ->
      Application.put_env(:tymeslot, :upload_directory, original_root)
      File.rm_rf(upload_root)
    end)

    %{profile: insert(:profile)}
  end

  defp stored_image(profile) do
    relative = "themes/#{profile.id}/1/images/mine.png"
    full = Storage.build_theme_file_path(relative)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "png")
    {relative, full}
  end

  test "replaces an uploaded image background and deletes its file", %{profile: profile} do
    {relative, full} = stored_image(profile)

    {:ok, _existing} =
      ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
        "background_type" => "image",
        "background_value" => "custom",
        "background_image_path" => relative
      })

    assert :ok = Onboarding.ensure_preview_video_backgrounds(profile, ["1"])

    saved = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
    assert saved.settings["background_type"] == "video"
    assert saved.settings["background_value"] in ThemeCustomizations.video_preset_keys("1")
    refute Map.has_key?(saved.settings, "background_image_path")
    refute File.exists?(full)
  end

  test "keeps the organiser's other choices", %{profile: profile} do
    {:ok, _existing} =
      ThemeCustomizations.apply_option(profile.id, "1", :palette, %{
        "field" => "scheme",
        "value" => "forest"
      })

    assert :ok = Onboarding.ensure_preview_video_backgrounds(profile, ["1"])

    saved = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
    assert saved.settings["color_scheme"] == "forest"
    assert saved.settings["background_type"] == "video"
  end
end
