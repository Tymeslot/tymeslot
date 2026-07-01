defmodule TymeslotWeb.Dashboard.OnboardingChecklistLiveTest do
  @moduledoc false
  use TymeslotWeb.ConnCase, async: true

  @moduletag :live
  @moduletag :onboarding

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

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

    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "[data-testid=onboarding-checklist]")
  end

  test "ticking an item greys it out immediately and persists", %{conn: conn} do
    {conn, user} = log_in_fresh_host(conn)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    refute has_element?(view, "button[phx-value-id='share'][aria-checked='true']")

    view
    |> element("button[phx-value-id='share']")
    |> render_click()

    # Greyed immediately in the live view...
    assert has_element?(view, "button[phx-value-id='share'][aria-checked='true']")
    # ...and persisted on the user.
    assert Onboarding.dashboard_setup_item_done?(Repo.get!(UserSchema, user.id), "share")
  end

  test "dismissing the widget hides it permanently", %{conn: conn} do
    {conn, user} = log_in_fresh_host(conn)
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "[data-testid=onboarding-checklist]")

    view
    |> element("button[phx-click='onboarding:dismiss']")
    |> render_click()

    refute has_element?(view, "[data-testid=onboarding-checklist]")
    assert Onboarding.dashboard_setup_dismissed?(Repo.get!(UserSchema, user.id))

    # Stays hidden on a fresh mount.
    {:ok, view2, _html} = live(conn, ~p"/dashboard")
    refute has_element?(view2, "[data-testid=onboarding-checklist]")
  end
end
