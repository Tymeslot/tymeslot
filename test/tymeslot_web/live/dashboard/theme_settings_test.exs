defmodule TymeslotWeb.Dashboard.ThemeSettingsTest do
  use TymeslotWeb.LiveCase, async: true
  @moduletag :utils

  import Tymeslot.TestHelpers.Eventually
  import Tymeslot.DashboardTestHelpers

  alias Tymeslot.Repo

  setup :setup_dashboard_user_with_theme

  describe "Theme selection" do
    test "renders theme options", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/theme")

      assert html =~ "Choose Your Style"
      assert html =~ "Quill"
      assert html =~ "Rhythm"
    end

    test "selects a theme", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      # Click on Rhythm theme card
      view
      |> element("[phx-click='select_theme'][phx-value-theme='2']")
      |> render_click()

      # Flash messages in Tymeslot might be rendered in a specific way or require a re-render
      # Let's check the database first to see if it worked
      assert Repo.reload!(profile).booking_theme == "2"

      # Now check the UI for "Current Style" label on the Rhythm theme
      assert render(view) =~ "Current Style"
    end
  end

  describe "Theme customization" do
    test "opens and closes customization", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      # Click on Customize Style for Quill theme (theme_id="1")
      view
      |> element("button[phx-value-theme='1']", "Customize Style")
      |> render_click()

      assert render(view) =~ "Customize Style"
      assert render(view) =~ "Color Palette"
      assert render(view) =~ "Background Design"

      # Close customization
      view
      |> element("button", "Close")
      |> render_click()

      assert render(view) =~ "Choose Your Style"
      refute render(view) =~ "Color Palette"
    end

    test "changes color scheme in customization", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      # Open customization for Quill
      view
      |> element("button[phx-value-theme='1']", "Customize Style")
      |> render_click()

      # Click on a color scheme
      view
      |> element("button[phx-click='theme:select_color_scheme'][phx-value-scheme='forest']")
      |> render_click()

      # The "Current" label should be present
      assert render(view) =~ "Current"
    end

    test "changes background type and selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      # Open customization for Quill
      view
      |> element("button[phx-value-theme='1']", "Customize Style")
      |> render_click()

      # Switch to "Solid Color" tab
      view
      |> element("button", "Solid Color")
      |> render_click()

      assert render(view) =~ "Select a solid color"

      # Select a color (e.g., #dc2626)
      view
      |> element("button[phx-value-id='#dc2626']")
      |> render_click()

      # Verify it's selected (check for the checkmark icon container)
      assert render(view) =~ "animate-in zoom-in"

      # Re-trigger update (simulated by some parent action, here just closing and re-opening
      # or we can just verify browsing_type is preserved across renders if we had a way to trigger it)
      # Actually, since it's a live component, let's just check that switching tabs works

      # Switch to Gradient tab
      view
      |> element("button", "Gradient")
      |> render_click()

      assert render(view) =~ "Gradient"
      refute render(view) =~ "Select a solid color"
    end

    test "handles background image upload safely", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      # Open customization for Quill
      view
      |> element("button[phx-value-theme='1']", "Customize Style")
      |> render_click()

      # Switch to Image tab
      view
      |> element("button", "Image")
      |> render_click()

      # Prepare file for upload
      image = %{
        last_modified: System.system_time(:millisecond),
        name: "bg.png",
        # Valid PNG content (IHDR chunk is usually required by many decoders)
        content: <<
          # Signature
          0x89,
          0x50,
          0x4E,
          0x47,
          0x0D,
          0x0A,
          0x1A,
          0x0A,
          # IHDR length
          0x00,
          0x00,
          0x00,
          0x0D,
          "IHDR",
          # Width 1
          0x00,
          0x00,
          0x00,
          0x01,
          # Height 1
          0x00,
          0x00,
          0x00,
          0x01,
          # Bit depth, Color type, etc.
          0x08,
          0x02,
          0x00,
          0x00,
          0x00,
          # CRC
          0x90,
          0x77,
          0x53,
          0xDE
        >>,
        type: "image/png"
      }

      # 1. Trigger the event with NO uploads - should not crash now thanks to upload_ready? check
      view
      |> element("#theme-background-image-form")
      |> render_submit()

      # 2. Simulate a successful upload
      # We use render_upload which both uploads and consumes if auto_upload is true
      # or if the component consumes it in progress.
      # ThemeCustomizationComponent has auto_upload: true and consumes in progress.
      view
      |> file_input("#theme-background-image-form", :background_image, [image])
      |> render_upload("bg.png")

      # Wait for async processing
      eventually(fn ->
        # Check for the success message in the flash
        # Flash messages are rendered in DashboardLive which wraps the component
        assert render(view) =~ "Background image uploaded successfully"
      end)
    end
  end
end
