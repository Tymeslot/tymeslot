defmodule TymeslotWeb.DashboardTourTest do
  @moduledoc false
  use TymeslotWeb.ConnCase, async: true

  @moduletag :live
  @moduletag :onboarding

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Onboarding.DashboardTour
  alias Tymeslot.Repo

  defp insert_fresh_dashboard_user(opts) do
    seen_at = Keyword.get(opts, :dashboard_tour_seen_at, nil)

    user =
      insert(:user,
        onboarding_completed_at: DateTime.utc_now(:second),
        dashboard_tour_seen_at: seen_at
      )

    _profile = insert(:profile, user: user)
    user
  end

  describe "tour eligibility" do
    test "renders the tour for a user who has not seen it", %{conn: conn} do
      user = insert_fresh_dashboard_user(dashboard_tour_seen_at: nil)

      conn = log_in_user(conn, user)
      {:ok, view, html} = live(conn, ~p"/dashboard")

      assert html =~ "dashboard-tour"
      assert has_element?(view, "#dashboard-tour")
    end

    test "does not render the tour for a user who has already seen it", %{conn: conn} do
      user = insert_fresh_dashboard_user(dashboard_tour_seen_at: DateTime.utc_now(:second))

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      refute has_element?(view, "#dashboard-tour")
    end

    test "does not render the tour on /dashboard/calendar even for fresh users", %{conn: conn} do
      user = insert_fresh_dashboard_user(dashboard_tour_seen_at: nil)

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar")

      refute has_element?(view, "#dashboard-tour")
    end
  end

  describe "step navigation" do
    setup %{conn: conn} do
      user = insert_fresh_dashboard_user(dashboard_tour_seen_at: nil)

      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/dashboard")
      %{view: view, user: user}
    end

    test "tour:next advances the step index", %{view: view} do
      assert view |> element("#dashboard-tour") |> render() =~ "data-step-index=\"0\""

      render_click(view, "tour:next")

      assert view |> element("#dashboard-tour") |> render() =~ "data-step-index=\"1\""
    end

    test "tour:back at step 0 stays at 0", %{view: view} do
      render_click(view, "tour:back")
      assert view |> element("#dashboard-tour") |> render() =~ "data-step-index=\"0\""
    end

    test "tour:next past the last step dismisses the overlay", %{view: view} do
      for _step <- 1..(DashboardTour.count() - 1), do: render_click(view, "tour:next")

      assert has_element?(view, "#dashboard-tour")

      render_click(view, "tour:next")

      refute has_element?(view, "#dashboard-tour")
    end

    test "tour:skip dismisses the overlay", %{view: view} do
      render_click(view, "tour:skip")
      refute has_element?(view, "#dashboard-tour")
    end

    test "tour:finish dismisses the overlay", %{view: view, user: user} do
      for _step <- 1..(DashboardTour.count() - 1), do: render_click(view, "tour:next")

      render_click(view, "tour:finish")
      refute has_element?(view, "#dashboard-tour")

      _user = user
    end
  end

  describe "marking seen" do
    test "tour:shown marks the user seen", %{conn: conn} do
      user = insert_fresh_dashboard_user(dashboard_tour_seen_at: nil)

      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/dashboard")
      render_hook(view, "tour:shown", %{})

      assert %DateTime{} = Repo.reload!(user).dashboard_tour_seen_at
    end

    test "tour:viewport-too-small marks seen and dismisses", %{conn: conn} do
      user = insert_fresh_dashboard_user(dashboard_tour_seen_at: nil)

      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/dashboard")
      render_hook(view, "tour:viewport-too-small", %{})

      refute has_element?(view, "#dashboard-tour")
      assert %DateTime{} = Repo.reload!(user).dashboard_tour_seen_at
    end
  end
end
