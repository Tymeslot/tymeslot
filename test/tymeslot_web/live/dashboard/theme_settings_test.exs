defmodule TymeslotWeb.Dashboard.ThemeSettingsTest do
  use TymeslotWeb.LiveCase, async: true
  @moduletag :utils

  import Tymeslot.Factory
  import Tymeslot.TestHelpers.Eventually
  import Tymeslot.DashboardTestHelpers

  alias Tymeslot.DatabaseSchemas.ThemeCustomizationSchema
  alias Tymeslot.Repo

  setup :setup_dashboard_user_with_theme

  describe "Theme selection" do
    test "renders theme options", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/theme")

      assert html =~ "Choose Your Style"
      assert html =~ "Quill"
      assert html =~ "Rhythm"
    end

    test "selects a theme and persists it", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      view
      |> element("[phx-click='select_theme'][phx-value-theme='2']")
      |> render_click()

      assert Repo.reload!(profile).booking_theme == "2"
      assert render(view) =~ "Current Style"
    end
  end

  describe "Theme customization" do
    test "opens and closes customization", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      view
      |> element("button[phx-value-theme='1']", "Customize Style")
      |> render_click()

      assert render(view) =~ "Customize Style"
      assert render(view) =~ "Color Palette"
      assert render(view) =~ "Background Design"

      view
      |> element("button", "Close")
      |> render_click()

      assert render(view) =~ "Choose Your Style"
      refute render(view) =~ "Color Palette"
    end

    test "navigates directly to the customize URL without going through the selection screen",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/theme/customize/1")

      assert html =~ "Color Palette"
      assert html =~ "Background Design"
    end

    test "loads saved customization when opening the customize view", %{
      conn: conn,
      profile: profile
    } do
      # "turquoise" is the scheme key whose display name is "Arctic Blue"
      insert(:theme_customization,
        profile: profile,
        theme_id: "1",
        color_scheme: "turquoise",
        background_type: "gradient",
        background_value: "gradient_1"
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      view
      |> element("button[phx-value-theme='1']", "Customize Style")
      |> render_click()

      # The Current badge (span.text-tymeslot-700) shows the loaded scheme's display name.
      # Scoping to that element rules out "Arctic Blue" appearing only in the scheme card list,
      # which is always rendered regardless of any saved customization.
      assert render(view) =~ ~r/text-tymeslot-700">Arctic Blue/
    end

    test "changes color scheme and persists it", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      view
      |> element("button[phx-value-theme='1']", "Customize Style")
      |> render_click()

      view
      |> element("button[phx-click='theme:select_color_scheme'][phx-value-scheme='forest']")
      |> render_click()

      # Scheme name appears in the "Current" badge
      assert render(view) =~ "Forest Green"

      saved = Repo.get_by(ThemeCustomizationSchema, profile_id: profile.id, theme_id: "1")
      assert saved.color_scheme == "forest"
    end

    test "changes background type tabs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      view
      |> element("button[phx-value-theme='1']", "Customize Style")
      |> render_click()

      view
      |> element("button", "Solid Color")
      |> render_click()

      assert render(view) =~ "Select a solid color"

      view
      |> element("button", "Gradient")
      |> render_click()

      refute render(view) =~ "Select a solid color"
    end

    test "selects a solid color background and persists it", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      view
      |> element("button[phx-value-theme='1']", "Customize Style")
      |> render_click()

      view
      |> element("button", "Solid Color")
      |> render_click()

      view
      |> element("button[phx-click='theme:select_background'][phx-value-id='#dc2626']")
      |> render_click()

      saved = Repo.get_by(ThemeCustomizationSchema, profile_id: profile.id, theme_id: "1")
      assert saved.background_type == "color"
      assert saved.background_value == "#dc2626"
    end

    test "handles background image upload safely", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      view
      |> element("button[phx-value-theme='1']", "Customize Style")
      |> render_click()

      view
      |> element("button", "Image")
      |> render_click()

      image = %{
        last_modified: System.system_time(:millisecond),
        name: "bg.png",
        content: <<
          0x89,
          0x50,
          0x4E,
          0x47,
          0x0D,
          0x0A,
          0x1A,
          0x0A,
          0x00,
          0x00,
          0x00,
          0x0D,
          "IHDR",
          0x00,
          0x00,
          0x00,
          0x01,
          0x00,
          0x00,
          0x00,
          0x01,
          0x08,
          0x02,
          0x00,
          0x00,
          0x00,
          0x90,
          0x77,
          0x53,
          0xDE
        >>,
        type: "image/png"
      }

      # Submitting with no file should not crash
      view
      |> element("#theme-background-image-form")
      |> render_submit()

      view
      |> file_input("#theme-background-image-form", :background_image, [image])
      |> render_upload("bg.png")

      eventually(fn ->
        assert render(view) =~ "Background image uploaded successfully"
      end)
    end
  end
end
