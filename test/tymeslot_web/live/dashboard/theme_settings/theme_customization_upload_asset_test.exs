defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomizationUploadAssetTest do
  @moduledoc """
  The theme customisation panel's `upload_asset` handler, which consumes a
  finished upload into the asset field it names. Both the progress callback
  and the form's submit reach it for one upload, so it must consume a
  finished entry exactly once, and an entry the rate limit held back on the
  first trigger must still be consumed on the next.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :live

  import Tymeslot.DashboardTestHelpers

  alias Phoenix.LiveComponent.CID
  alias Phoenix.LiveView
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
    {:ok, view, _html} = live(conn, "/dashboard/theme/customize/#{theme_id}")

    view
    |> element("button[phx-click='theme:set_browsing_type'][phx-value-type='#{kind}']")
    |> render_click()

    view
  end

  describe "the upload_asset handler" do
    setup :isolated_upload_root

    setup %{user: user} do
      bucket = "theme_upload:#{user.id}"
      RateLimiter.clear_bucket(bucket)
      on_exit(fn -> RateLimiter.clear_bucket(bucket) end)
      %{bucket: bucket}
    end

    test "consumes a finished entry the progress callback was refused",
         %{conn: conn, profile: profile, bucket: bucket} do
      for _i <- 1..5, do: assert(:ok = RateLimiter.check(:theme_upload, profile.user_id))

      view = open_tab(conn, "1", "image")

      image = %{
        last_modified: System.system_time(:millisecond),
        name: "background.png",
        content: @valid_png,
        type: "image/png"
      }

      view
      |> file_input("#theme-background-image-form", :background_image_path, [image])
      |> render_upload("background.png")

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1") == nil

      RateLimiter.clear_bucket(bucket)
      view |> form("#theme-background-image-form") |> render_submit()

      assert_push_event(view, "upload-complete", _payload)

      saved = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
      assert saved.settings["background_type"] == "image"
      assert saved.settings["background_image_path"] =~ "themes/#{profile.id}/1/images/"
    end

    # In the browser both triggers fire for one finished upload: the progress
    # callback, and the submit `AutoUpload` clicks, which LiveView sends once
    # the upload completes. The second reaches the LiveView before it has
    # handled the upload channel's exit, so the consumed entry still looks
    # finished. Holding the LiveView while both are queued reproduces that
    # order; consuming the entry again called into the stopped channel and
    # crashed the LiveView, after the file was saved.
    test "a second consume queued behind the first is a no-op",
         %{conn: conn, profile: profile, bucket: bucket} do
      for _i <- 1..5, do: assert(:ok = RateLimiter.check(:theme_upload, profile.user_id))

      view = open_tab(conn, "1", "image")

      image = %{
        last_modified: System.system_time(:millisecond),
        name: "background.png",
        content: @valid_png,
        type: "image/png"
      }

      view
      |> file_input("#theme-background-image-form", :background_image_path, [image])
      |> render_upload("background.png")

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1") == nil
      RateLimiter.clear_bucket(bucket)

      [cid] =
        Regex.run(
          ~r/data-phx-component="(\d+)"/,
          view |> element("#theme-customization-uploads") |> render(),
          capture: :all_but_first
        )

      :sys.suspend(view.pid)

      for _i <- 1..2 do
        LiveView.send_update(view.pid, %CID{cid: String.to_integer(cid)},
          consume_upload: :background_image_path
        )
      end

      :sys.resume(view.pid)

      assert has_element?(view, "[data-testid='uploaded-image']")
      assert Process.alive?(view.pid)

      saved = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
      assert saved.settings["background_image_path"] =~ "themes/#{profile.id}/1/images/"
    end

    test "a field the theme does not declare saves nothing",
         %{conn: conn, profile: profile} do
      view = open_tab(conn, "1", "image")

      view |> form("#theme-background-image-form") |> render_change(%{"asset_field" => "bogus"})

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1") == nil
    end
  end
end
