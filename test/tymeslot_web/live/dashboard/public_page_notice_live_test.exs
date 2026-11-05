defmodule TymeslotWeb.Dashboard.PublicPageNoticeLiveTest do
  @moduledoc """
  A host who finished onboarding without a calendar a booking can be written
  to has a public page that refuses every visitor. The dashboard tells them so
  on every page, in a notice they cannot dismiss, with one click to fix it;
  and a host whose calendar later stopped working is offered a repair, never
  redirected away from the dashboard.
  """
  use TymeslotWeb.ConnCase, async: true

  @moduletag :live
  @moduletag :dashboard

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Onboarding
  alias Tymeslot.Security.Encryption

  @notice "[data-testid=public-page-notice]"
  @connect_notice "[data-testid=public-page-notice][data-kind=connect]"
  @repair_notice "[data-testid=public-page-notice][data-kind=repair]"
  @notice_action "[data-testid=public-page-notice-action][href='/dashboard/integrations?tab=calendars']"

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    profile = insert(:profile, user: user)
    %{conn: log_in_user(conn, user), user: user, profile: profile}
  end

  describe "a host who never connected a calendar" do
    test "is told on every dashboard page that guests see the page as unavailable",
         %{conn: conn} do
      for path <- [~p"/dashboard/overview", ~p"/dashboard/meeting-settings", ~p"/dashboard"] do
        {:ok, view, _html} = live(conn, path)

        assert view |> element(@connect_notice) |> render() =~
                 "Anyone who opens your link is told the page isn&#39;t available until you connect a calendar.",
               "no connect notice on #{path}"

        assert view |> element(@notice_action) |> render() =~ "Connect a calendar"
      end
    end

    test "the notice links straight to connecting a calendar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/overview")

      assert {:error, {:live_redirect, %{to: "/dashboard/integrations?tab=calendars"}}} =
               view |> element(@notice_action) |> render_click()
    end

    test "keeps the notice after the setup checklist is dismissed", %{conn: conn, user: user} do
      {:ok, _user} = Onboarding.dismiss_dashboard_setup(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/overview")

      refute has_element?(view, "[data-testid=onboarding-checklist]")
      assert has_element?(view, @connect_notice)
      # Nothing on the notice closes it.
      refute view |> element(@notice) |> render() =~ "phx-click"
    end

    test "puts the calendar first in the setup checklist, saying what is at stake",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/overview")

      [first_item | _rest] =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.find("[data-testid=onboarding-checklist] li")

      assert Floki.text(first_item) =~ "Connect a calendar"
      assert Floki.text(first_item) =~ "Your booking page can't take bookings without one"
    end

    test "the calendar grid's own connect banner gives way to the notice",
         %{conn: conn, user: user} do
      {:ok, _user} = Onboarding.dismiss_dashboard_setup(user)

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      assert has_element?(view, @connect_notice)
      refute has_element?(view, "[data-testid=connect-calendar-banner]")
    end

    test "is not shown on the integrations page it links to", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations")

      refute has_element?(view, @notice)
    end
  end

  describe "a host whose calendar stopped working" do
    test "a switched-off calendar keeps the dashboard and gets a repair prompt",
         %{conn: conn, user: user} do
      insert(:calendar_integration, user: user, provider: "caldav", is_active: false)

      assert {:ok, view, _html} = live(conn, ~p"/dashboard/overview")

      assert view |> element(@repair_notice) |> render() =~
               "Your booking page has stopped taking bookings"

      assert view |> element(@notice_action) |> render() =~ "Fix calendar connection"
      refute has_element?(view, @connect_notice)
    end

    test "a subscription-only account is prompted to repair, not to start over",
         %{conn: conn, user: user} do
      insert(:calendar_integration,
        user: user,
        provider: "ics_url",
        base_url: "https://feeds.example.com",
        username_encrypted: nil,
        password_encrypted: nil,
        subscription_url_encrypted: Encryption.encrypt("https://feeds.example.com/feed.ics")
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/overview")

      assert has_element?(view, @repair_notice)
    end

    test "an expired calendar keeps the dashboard and is left to its reconnect notice",
         %{conn: conn, user: user} do
      insert(:calendar_integration, user: user, provider: "apple", needs_reauth: true)

      assert {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      assert has_element?(view, "#refused-calendar-notice")
      refute has_element?(view, @notice)
    end
  end

  test "a host with a working calendar sees no notice", %{conn: conn, user: user} do
    insert(:calendar_integration, user: user, provider: "caldav")

    {:ok, view, _html} = live(conn, ~p"/dashboard/overview")

    refute has_element?(view, @notice)
    refute has_element?(view, "#refused-calendar-notice")
  end
end
