defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomizationUploadAssetTest do
  @moduledoc """
  How the theme customisation panel saves an upload: its progress callback
  saves a finished entry, and nothing else does, so one upload is saved once.
  The form's `upload_asset` change event only validates. An entry the rate
  limit refused is cancelled, and the file is saved when picked again.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :live

  import Tymeslot.DashboardTestHelpers

  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Test.MediaFixtures
  alias Tymeslot.Test.UploadRoot
  alias Tymeslot.ThemeCustomizations

  # Complete and decodable: a stored image is re-encoded, so magic bytes
  # alone are refused.
  @valid_png MediaFixtures.png()

  setup :setup_dashboard_user_with_theme

  defp isolated_upload_root(_context), do: %{upload_root: UploadRoot.isolate()}

  defp open_tab(conn, theme_id, kind) do
    {:ok, view, _html} = live(conn, "/dashboard/pages/customize/#{theme_id}")

    view
    |> element("button[phx-click='theme:set_browsing_type'][phx-value-type='#{kind}']")
    |> render_click()

    view
  end

  defp image(name) do
    %{
      last_modified: System.system_time(:millisecond),
      name: name,
      content: @valid_png,
      type: "image/png"
    }
  end

  # `render/1` pings the LiveView, so a save the progress callback queued has
  # run once it returns.
  defp upload(view, name \\ "background.png") do
    view
    |> file_input("#theme-background-image-form", :background_image_path, [image(name)])
    |> render_upload(name)

    render(view)
  end

  defp exhaust_limit(profile),
    do: for(_i <- 1..5, do: assert(:ok = RateLimiter.check(:theme_upload, profile.user_id)))

  describe "saving an upload" do
    setup :isolated_upload_root

    setup %{user: user} do
      bucket = "theme_upload:#{user.id}"
      RateLimiter.clear_bucket(bucket)
      on_exit(fn -> RateLimiter.clear_bucket(bucket) end)
      %{bucket: bucket}
    end

    test "a finished upload is saved into its field",
         %{conn: conn, profile: profile, upload_root: root} do
      view = open_tab(conn, "1", "image")

      upload(view)

      saved = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
      assert saved.settings["background_type"] == "image"
      assert saved.settings["background_image_path"] =~ "themes/#{profile.id}/1/images/"
      assert [_one_file] = File.ls!(Path.join(root, "themes/#{profile.id}/1/images"))
    end

    test "an upload the rate limit refused is saved when the file is picked again",
         %{conn: conn, profile: profile, bucket: bucket} do
      exhaust_limit(profile)
      view = open_tab(conn, "1", "image")

      upload(view)
      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1") == nil
      # The refused entry is cancelled rather than left at 100% in the picker,
      # and the user is told why.
      refute has_element?(view, "#theme-background-image-form", "background.png")
      assert render(view) =~ "Too many upload attempts"

      RateLimiter.clear_bucket(bucket)
      # Under another name: the test client tracks an upload by its file name.
      upload(view, "again.png")

      saved = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
      assert saved.settings["background_image_path"] =~ "themes/#{profile.id}/1/images/"
    end
  end
end
