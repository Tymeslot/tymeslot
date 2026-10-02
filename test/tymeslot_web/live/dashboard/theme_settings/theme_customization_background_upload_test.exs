defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomizationBackgroundUploadTest do
  @moduledoc """
  Verifies a successful background image upload in the theme customizer
  pushes "upload-complete" so the `AutoUpload` hook clears the file picker,
  mirroring the avatar upload fixes (dashboard and onboarding), and that what
  is published carries none of the uploaded file's metadata.
  """

  use TymeslotWeb.LiveCase, async: false

  alias Tymeslot.Test.MediaFixtures
  alias Tymeslot.ThemeCustomizations

  @moduletag :themes
  @moduletag :live

  import Tymeslot.DashboardTestHelpers

  # Complete and decodable: a stored image is re-encoded, so magic bytes
  # alone are refused.
  @valid_png MediaFixtures.png()

  setup :setup_dashboard_user_with_theme

  describe "background image upload" do
    test "a successful upload pushes upload-complete so the AutoUpload hook clears the picker",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      view
      |> element("button[phx-value-theme='1']", "Customize Style")
      |> render_click()

      # Switch to the image tab, which renders the upload form.
      view
      |> element("button[phx-click='theme:set_browsing_type'][phx-value-type='image']")
      |> render_click()

      image = %{
        last_modified: System.system_time(:millisecond),
        name: "background.png",
        content: @valid_png,
        type: "image/png"
      }

      view
      |> file_input("#theme-background-image-form", :background_image, [image])
      |> render_upload("background.png")

      assert_push_event(view, "upload-complete", %{})
    end

    test "publishes a WebP background without its EXIF location", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")
      open_image_tab(view)

      image = %{
        last_modified: System.system_time(:millisecond),
        name: "garden.webp",
        content: MediaFixtures.read!("gps.webp"),
        type: "image/webp"
      }

      view
      |> file_input("#theme-background-image-form", :background_image, [image])
      |> render_upload("garden.webp")

      assert_push_event(view, "upload-complete", %{})

      customization = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
      response = get(build_conn(), "/uploads/" <> customization.background_image_path)
      assert response.status == 200
      assert MediaFixtures.image_metadata_fields(response.resp_body) == []
      refute response.resp_body =~ "Model-X"
    end

    test "refuses an image over 40 megapixels and says how large it may be", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")
      open_image_tab(view)

      image = %{
        last_modified: System.system_time(:millisecond),
        name: "huge.png",
        content: MediaFixtures.png_declaring(20_000, 20_000),
        type: "image/png"
      }

      view
      |> file_input("#theme-background-image-form", :background_image, [image])
      |> render_upload("huge.png")

      assert render(view) =~
               "This image is too large (400.0 megapixels). " <>
                 "Please upload an image of at most 40 megapixels."

      refute match?(
               %{background_image_path: path} when is_binary(path),
               ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
             )
    end
  end

  describe "background video upload" do
    test "refuses a QuickTime file", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      view
      |> element("button[phx-value-theme='1']", "Customize Style")
      |> render_click()

      view
      |> element("button[phx-click='theme:set_browsing_type'][phx-value-type='video']")
      |> render_click()

      video = %{
        last_modified: System.system_time(:millisecond),
        name: "clip.mov",
        content: <<0, 0, 0, 20, "ftypqt  ", 0, 0, 0, 0, "qt  ">>,
        type: "video/quicktime"
      }

      assert {:error, [[_ref, :not_accepted]]} =
               view
               |> file_input("#theme-background-video-form", :background_video, [video])
               |> render_upload("clip.mov")
    end
  end

  defp open_image_tab(view) do
    view
    |> element("button[phx-value-theme='1']", "Customize Style")
    |> render_click()

    view
    |> element("button[phx-click='theme:set_browsing_type'][phx-value-type='image']")
    |> render_click()
  end
end
