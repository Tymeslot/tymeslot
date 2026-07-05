defmodule TymeslotWeb.DashboardRoutesTest do
  use TymeslotWeb.LiveCase, async: false
  @moduletag :live
  @moduletag :meetings

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Phoenix.Flash
  alias Tymeslot.Infrastructure.DashboardCache

  setup_all do
    case Process.whereis(DashboardCache) do
      nil -> start_supervised!(DashboardCache)
      _pid -> :ok
    end

    :ok
  end

  defp setup_authenticated_user(conn) do
    DashboardCache.clear_all()

    user =
      insert(:user,
        onboarding_completed_at: DateTime.utc_now(),
        dashboard_tour_seen_at: DateTime.utc_now()
      )

    profile =
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

    %{conn: conn, user: user, profile: profile}
  end

  describe "authentication" do
    test "dashboard requires login", %{conn: conn} do
      conn = get(conn, ~p"/dashboard")

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "You must be logged in"
    end
  end

  describe "disconnected mount" do
    setup %{conn: conn} do
      {:ok, setup_authenticated_user(conn)}
    end

    test "dashboard returns HTML before WebSocket upgrade", %{conn: conn} do
      conn = get(conn, ~p"/dashboard")
      assert html_response(conn, 200) =~ "dashboard"

      {:ok, _view, _html} = live(conn)
    end
  end

  describe "dashboard pages" do
    setup %{conn: conn} do
      {:ok, setup_authenticated_user(conn)}
    end

    @routes [
      {"/dashboard", "Welcome back"},
      {"/dashboard/settings", "Profile Settings"},
      {"/dashboard/availability", "Availability"},
      {"/dashboard/meeting-settings", "Meeting Settings"},
      {"/dashboard/calendar", "calendar-grid"},
      {"/dashboard/integrations", "Integrations"},
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

    # The standalone calendar/video/payments pages are now tabs in the unified
    # hub. Their routes stay defined (deep links, emails and OAuth/Stripe returns
    # still target them) but redirect to the matching hub tab.
    @legacy_redirects [
      {"/dashboard/calendar-integration", "/dashboard/integrations?tab=calendars"},
      {"/dashboard/video-integration", "/dashboard/integrations?tab=video"},
      {"/dashboard/payments", "/dashboard/integrations?tab=payments"}
    ]

    for {from, to} <- @legacy_redirects do
      test "#{from} redirects into the hub", %{conn: conn} do
        assert {:error, {:live_redirect, %{to: unquote(to)}}} =
                 live(conn, unquote(from))
      end
    end

    test "/dashboard/payments?return=1 carries the Stripe return marker into the hub redirect",
         %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "/dashboard/payments?return=1")

      assert to =~ "tab=payments"
      assert to =~ "return=1"
    end

    test "/dashboard/payments?refresh=1 carries the Stripe refresh marker into the hub redirect",
         %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "/dashboard/payments?refresh=1")

      assert to =~ "tab=payments"
      assert to =~ "refresh=1"
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

  describe "overview" do
    setup %{conn: conn} do
      {:ok, setup_authenticated_user(conn)}
    end

    test "shows the user's full name in the welcome banner", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Welcome back, Test User"
    end

    test "shows empty state when no meetings are scheduled", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Nothing on your plate today or tomorrow."
    end

    test "shows upcoming meeting title and attendee name", %{conn: conn, user: user} do
      insert(:meeting,
        organizer_email: user.email,
        title: "Strategy Session",
        attendee_name: "Jane Smith"
      )

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Strategy Session"
      assert html =~ "Jane Smith"
    end

    test "updates welcome banner name when profile is updated", %{conn: conn, profile: profile} do
      {:ok, view, html} = live(conn, ~p"/dashboard")
      assert html =~ "Welcome back, Test User"

      send(view.pid, {:profile_updated, %{profile | full_name: "Updated Name"}})

      assert render(view) =~ "Updated Name"
    end

    test "refreshes meeting list after meeting type is changed", %{conn: conn, user: user} do
      {:ok, view, html} = live(conn, ~p"/dashboard")
      assert html =~ "Nothing on your plate today or tomorrow."

      insert(:meeting,
        organizer_email: user.email,
        title: "Newly Scheduled Meeting"
      )

      send(view.pid, {:meeting_type_changed})

      assert render(view) =~ "Newly Scheduled Meeting"
    end
  end

  describe "mode tab bar" do
    setup %{conn: conn} do
      {:ok, setup_authenticated_user(conn)}
    end

    test "renders mode tab bar on scheduling pages", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")
      assert html =~ "mode-tab-bar"
    end

    test "renders mode tab bar on calendar page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ "mode-tab-bar"
    end

    test "sidebar is present in scheduling mode", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")
      assert html =~ "dashboard-sidebar"
    end

    test "sidebar is absent in calendar mode", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/calendar")
      refute html =~ "dashboard-sidebar"
    end

    test "scheduling tab is active on non-calendar pages", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")
      doc = Floki.parse_document!(html)
      [scheduling_tab] = Floki.find(doc, "[data-testid='mode-tab-scheduling']")
      classes = scheduling_tab |> Floki.attribute("class") |> List.first() |> String.split()
      assert "mode-tab--active" in classes
    end

    test "calendar tab is active on /dashboard/calendar", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/calendar")
      doc = Floki.parse_document!(html)
      [calendar_tab] = Floki.find(doc, "[data-testid='mode-tab-calendar']")
      classes = calendar_tab |> Floki.attribute("class") |> List.first() |> String.split()
      assert "mode-tab--active" in classes
    end
  end

  describe "overview - nil full name" do
    setup %{conn: conn} do
      DashboardCache.clear_all()

      user =
        insert(:user,
          onboarding_completed_at: DateTime.utc_now(),
          dashboard_tour_seen_at: DateTime.utc_now()
        )

      insert(:profile,
        user: user,
        username: "noname",
        full_name: nil,
        booking_theme: "1"
      )

      conn =
        conn
        |> init_test_session(%{})
        |> log_in_user(user)

      {:ok, %{conn: conn}}
    end

    test "shows welcome banner without name when full_name is nil", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Welcome back!"
    end
  end

  describe "overview - first visit" do
    setup %{conn: conn} do
      DashboardCache.clear_all()

      # Onboarding is complete (so no redirect) but the dashboard tour has
      # never been seen — the hallmark of a first dashboard visit.
      user =
        insert(:user,
          onboarding_completed_at: DateTime.utc_now(),
          dashboard_tour_seen_at: nil
        )

      insert(:profile,
        user: user,
        username: "firsttimer",
        full_name: "First Timer",
        booking_theme: "1"
      )

      conn =
        conn
        |> init_test_session(%{})
        |> log_in_user(user)

      {:ok, %{conn: conn}}
    end

    test "greets a first-time visitor with 'Welcome' rather than 'Welcome back'", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Welcome, First Timer"
      refute html =~ "Welcome back"
    end
  end

  describe "onboarding redirect" do
    test "redirects to onboarding when onboarding is not completed", %{conn: conn} do
      DashboardCache.clear_all()
      user = insert(:user, onboarding_completed_at: nil)
      insert(:profile, user: user, username: "incomplete", booking_theme: "1")

      conn =
        conn
        |> init_test_session(%{})
        |> log_in_user(user)

      assert {:error, {:redirect, %{to: "/onboarding"}}} = live(conn, ~p"/dashboard")
    end
  end

  describe "overview - invalid timezone" do
    setup %{conn: conn} do
      DashboardCache.clear_all()

      user =
        insert(:user,
          onboarding_completed_at: DateTime.utc_now(),
          dashboard_tour_seen_at: DateTime.utc_now()
        )

      insert(:profile,
        user: user,
        username: "badtz",
        full_name: "Bad TZ User",
        timezone: "Invalid/Timezone",
        booking_theme: "1"
      )

      conn =
        conn
        |> init_test_session(%{})
        |> log_in_user(user)

      {:ok, %{conn: conn, user: user}}
    end

    test "renders meeting without crashing when profile timezone is invalid", %{
      conn: conn,
      user: user
    } do
      insert(:meeting,
        organizer_email: user.email,
        title: "Timeless Meeting",
        attendee_name: "Jane"
      )

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      # Meeting still renders even with invalid timezone — time falls back to UTC
      assert html =~ "Timeless Meeting"
      assert html =~ "Jane"
    end
  end

  describe "external redirect validation" do
    setup %{conn: conn} do
      {:ok, setup_authenticated_user(conn)}
    end

    test "allows HTTPS external redirects", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      send(view.pid, {:external_redirect, "https://accounts.google.com/o/oauth2/auth"})

      assert_redirect(view, "https://accounts.google.com/o/oauth2/auth")
    end

    test "rejects non-HTTPS external redirects", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      send(view.pid, {:external_redirect, "http://evil.com/phish"})

      html = render(view)
      assert html =~ "Invalid redirect URL"
    end

    test "rejects javascript: scheme redirects", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      send(view.pid, {:external_redirect, "javascript:alert(1)"})

      html = render(view)
      assert html =~ "Invalid redirect URL"
    end
  end

  describe "handle_info resilience" do
    setup %{conn: conn} do
      {:ok, setup_authenticated_user(conn)}
    end

    test "silently ignores unknown messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      send(view.pid, {:completely_unknown_message, "some data"})

      # Should not crash, should still render the dashboard
      assert render(view) =~ "Welcome back"
    end
  end
end
