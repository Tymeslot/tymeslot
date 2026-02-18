defmodule TymeslotWeb.DashboardRoutesTest do
  @moduletag :utils
  use TymeslotWeb.LiveCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Phoenix.Flash
  alias Tymeslot.Infrastructure.DashboardCache

  setup_all do
  @moduletag :utils
    case Process.whereis(DashboardCache) do
      nil -> start_supervised!(DashboardCache)
      _pid -> :ok
    end

    :ok
  end

  describe "authentication" do
    test "dashboard requires login", %{conn: conn} do
      conn = get(conn, ~p"/dashboard")

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "You must be logged in"
    end
  end

  describe "dashboard pages" do
    setup %{conn: conn} do
      DashboardCache.clear_all()

      user = insert(:user, onboarding_completed_at: DateTime.utc_now())

      _profile =
        insert(:profile,
          user: user,
          username: "testuser",
          full_name: "Test User",
          booking_theme: "1"
        )

      conn =
        conn
        |> init_test_session(%{})
        |> log_in_user(user)

      %{conn: conn, user: user}
    end

    @routes [
      {"/dashboard", "Welcome back"},
      {"/dashboard/settings", "Profile Settings"},
      {"/dashboard/availability", "Availability"},
      {"/dashboard/meeting-settings", "Meeting Settings"},
      {"/dashboard/calendar", "Calendar Integration"},
      {"/dashboard/video", "Video Integration"},
      {"/dashboard/theme", "Choose Your Style"},
      {"/dashboard/meetings", "Meetings"},
      {"/dashboard/automation", "Automation"}
    ]

    for {path, expected_text} <- @routes do
      test "renders #{path}", %{conn: conn} do
        {:ok, _view, html} = live(conn, unquote(path))
        assert html =~ unquote(expected_text)
      end
    end

    test "overview quick action navigates to settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view
      |> element("a", "Profile Settings")
      |> render_click()

      assert_patch(view, ~p"/dashboard/settings")
      assert render(view) =~ "Profile Settings"
    end

    test "availability can switch to grid view", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/availability")

      assert render(view) =~ "Weekly Schedule"

      view
      |> element("button[phx-click='toggle_input_mode'][phx-value-option='grid']")
      |> render_click()

      assert render(view) =~ "Availability"
      assert render(view) =~ "Weekly Visual Grid"
    end

    test "meeting settings can open the add meeting type form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/meeting-settings")

      view
      |> element("button", "Add Meeting Type")
      |> render_click()

      assert render(view) =~ "Add Meeting Type"
      assert has_element?(view, "form[phx-submit='save_meeting_type']")
    end

    test "theme customization can be opened and browsed", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/theme")

      view
      |> element("button[phx-click='show_customization'][phx-value-theme='1']")
      |> render_click()

      assert render(view) =~ "Customize Style"
      assert has_element?(view, "#theme-customization-uploads")

      view
      |> element("button[phx-click='theme:set_browsing_type'][phx-value-type='color']")
      |> render_click()

      assert render(view) =~ "Select a solid color"

      view
      |> element("button[phx-click='theme:set_browsing_type'][phx-value-type='image']")
      |> render_click()

      assert has_element?(view, "#theme-background-image-form")

      view
      |> element("button[phx-click='theme:set_browsing_type'][phx-value-type='video']")
      |> render_click()

      assert has_element?(view, "#theme-background-video-form")
    end
  end
end
