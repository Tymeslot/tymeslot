defmodule Tymeslot.Onboarding.PreviewVideoBackgroundsTest do
  @moduledoc """
  Onboarding's preview video is a background choice like any other: an
  uploaded image stays stored, and the rest of the customisation is left
  alone. It is made only where the row stores no video background yet,
  decided on the locked row.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :onboarding
  @moduletag :themes

  alias Tymeslot.Onboarding
  alias Tymeslot.Test.UploadRoot
  alias Tymeslot.ThemeCustomizations

  setup do
    UploadRoot.isolate("tymeslot_preview_video")

    %{profile: insert(:profile)}
  end

  defp stored_image(profile) do
    relative = "themes/#{profile.id}/1/images/mine.png"
    full = UploadRoot.path(relative)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "png")
    {relative, full}
  end

  test "shows a preset video, keeping an uploaded image stored to switch back to", %{
    profile: profile
  } do
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
    assert saved.settings["background_image_path"] == relative
    assert File.exists?(full)
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

  test "leaves a video background the row stores alone", %{profile: profile} do
    {:ok, _existing} =
      ThemeCustomizations.apply_option(profile.id, "1", :background, %{
        "field" => "video",
        "value" => "preset:leaves"
      })

    assert :ok = Onboarding.ensure_preview_video_backgrounds(profile, ["1"])

    assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1").settings[
             "background_value"
           ] == "preset:leaves"
  end
end
