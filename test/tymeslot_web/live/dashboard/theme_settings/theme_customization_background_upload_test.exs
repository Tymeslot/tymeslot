defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomizationBackgroundUploadTest do
  @moduledoc """
  Verifies a successful background image upload in the theme customizer
  pushes "upload-complete" so the `AutoUpload` hook clears the file picker,
  mirroring the avatar upload fixes (dashboard and onboarding).
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :live

  import Tymeslot.DashboardTestHelpers

  # Minimal valid PNG (magic bytes + IHDR) — accepted by allow_upload's accept
  # list without triggering the file-size limit.
  @valid_png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 0, 0, 0, 1, 0,
               0, 0, 1, 8, 2, 0, 0, 0, 0x90, 0x77, 0x53, 0xDE>>

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
  end
end
