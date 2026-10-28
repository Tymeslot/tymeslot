defmodule TymeslotWeb.Dashboard.OnboardingChecklistLiveTest do
  @moduledoc false
  use TymeslotWeb.ConnCase, async: true

  @moduletag :live
  @moduletag :onboarding

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Onboarding
  alias Tymeslot.Repo

  defp log_in_fresh_host(conn) do
    # No integrations, nothing ticked — every setup item is outstanding.
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    _profile = insert(:profile, user: user)
    {log_in_user(conn, user), user}
  end

  test "shows the setup widget to a host with setup still outstanding", %{conn: conn} do
    {conn, _user} = log_in_fresh_host(conn)

    {:ok, view, _html} = live(conn, ~p"/dashboard/overview")

    assert has_element?(view, "[data-testid=onboarding-checklist]")
  end

  # A refused calendar is still connected, but the booking page offers no
  # times until it is reconnected, so the dashboard must stop calling it done.
  describe "a calendar whose credentials were refused" do
    setup %{conn: conn} do
      {conn, user} = log_in_fresh_host(conn)
      %{conn: conn, user: user}
    end

    test "un-ticks the calendar item and says so on every page", %{conn: conn, user: user} do
      integration = insert(:calendar_integration, user: user, provider: "apple", name: "iCloud")

      calendar_cta =
        "[data-testid=onboarding-checklist] a[href='/dashboard/integrations?tab=calendars']"

      {:ok, view, _html} = live(conn, ~p"/dashboard/overview")
      refute has_element?(view, calendar_cta)
      refute has_element?(view, "#refused-calendar-notice")

      Repo.update!(Changeset.change(integration, needs_reauth: true))

      {:ok, view, _html} = live(conn, ~p"/dashboard/overview")
      assert has_element?(view, calendar_cta)

      assert view |> element("#refused-calendar-notice") |> render() =~
               "iCloud needs reconnecting. Until you reconnect it, your booking page may not offer times or take bookings."

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      assert has_element?(
               view,
               "#refused-calendar-notice a[href='/dashboard/integrations?tab=calendars']"
             )
    end

    test "leaves the notice off the integrations page, which has its own banner",
         %{conn: conn, user: user} do
      insert(:calendar_integration, user: user, provider: "apple", needs_reauth: true)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations")
      refute has_element?(view, "#refused-calendar-notice")
    end
  end

  test "ticking an item greys it out immediately and persists", %{conn: conn} do
    {conn, user} = log_in_fresh_host(conn)
    {:ok, view, _html} = live(conn, ~p"/dashboard/overview")

    refute has_element?(view, "button[phx-value-id='share'][aria-checked='true']")

    view
    |> element("button[phx-value-id='share']")
    |> render_click()

    # Greyed immediately in the live view...
    assert has_element?(view, "button[phx-value-id='share'][aria-checked='true']")
    # ...and persisted on the user.
    assert "share" in (Repo.get!(UserSchema, user.id).dashboard_setup_done_items || [])
  end

  test "unticking an item restores it and persists", %{conn: conn} do
    {conn, user} = log_in_fresh_host(conn)
    {:ok, view, _html} = live(conn, ~p"/dashboard/overview")

    view |> element("button[phx-value-id='theme']") |> render_click()
    assert "theme" in Repo.get!(UserSchema, user.id).dashboard_setup_done_items

    view |> element("button[phx-value-id='theme']") |> render_click()

    assert has_element?(view, "button[phx-value-id='theme'][aria-checked='false']")
    assert Repo.get!(UserSchema, user.id).dashboard_setup_done_items == []
  end

  test "a forged toggle for a provider item persists nothing", %{conn: conn} do
    {conn, user} = log_in_fresh_host(conn)
    {:ok, view, _html} = live(conn, ~p"/dashboard/overview")

    # No checkbox is rendered for it, so only a hand-crafted event can send it.
    render_hook(view, "onboarding:toggle", %{"id" => "calendar"})

    assert Repo.get!(UserSchema, user.id).dashboard_setup_done_items == []
    assert has_element?(view, "[data-testid=onboarding-checklist]")
  end

  test "dismissing the widget hides it permanently", %{conn: conn} do
    {conn, user} = log_in_fresh_host(conn)
    {:ok, view, _html} = live(conn, ~p"/dashboard/overview")

    assert has_element?(view, "[data-testid=onboarding-checklist]")

    view
    |> element("button[phx-click='onboarding:dismiss']")
    |> render_click()

    refute has_element?(view, "[data-testid=onboarding-checklist]")
    assert Onboarding.dashboard_setup_dismissed?(Repo.get!(UserSchema, user.id))

    # Stays hidden on a fresh mount.
    {:ok, view2, _html} = live(conn, ~p"/dashboard/overview")
    refute has_element?(view2, "[data-testid=onboarding-checklist]")
  end
end
