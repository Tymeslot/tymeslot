defmodule TymeslotWeb.DashboardTourAnchorsTest do
  @moduledoc false
  use TymeslotWeb.ConnCase, async: true

  @moduletag :live
  @moduletag :onboarding

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Onboarding
  alias Tymeslot.Onboarding.DashboardTour

  defp insert_host(attrs \\ []) do
    user =
      insert(
        :user,
        Keyword.merge(
          [onboarding_completed_at: DateTime.utc_now(:second), dashboard_tour_seen_at: nil],
          attrs
        )
      )

    _profile = insert(:profile, user: user)
    user
  end

  defp anchors(steps), do: steps |> Enum.map(& &1.anchor) |> Enum.reject(&is_nil/1)

  test "every non-nil step anchor resolves to a data-tour element on /dashboard", %{conn: conn} do
    user = insert_host()

    {:ok, _view, html} = live(log_in_user(conn, user), ~p"/dashboard")

    # A fresh host has setup outstanding, so the checklist step is in play.
    steps = DashboardTour.steps(%{checklist_visible?: true})
    assert Enum.any?(steps, &(&1.id == :quick_actions))

    for anchor <- anchors(steps) do
      assert html =~ ~s(data-tour="#{anchor}"),
             "expected to find data-tour=\"#{anchor}\" in rendered /dashboard HTML"
    end
  end

  test "a host who dismissed the checklist gets a tour without that step", %{conn: conn} do
    user = insert_host()
    {:ok, user} = Onboarding.dismiss_dashboard_setup(user)

    {:ok, view, html} = live(log_in_user(conn, user), ~p"/dashboard")

    # The anchor really is gone from the page...
    refute html =~ ~s(data-tour="quick-actions")

    # ...so the step is dropped rather than spotlit and skipped by the client,
    # and the count the host reads matches the steps they will actually see.
    steps = DashboardTour.steps(%{checklist_visible?: false})
    refute Enum.any?(steps, &(&1.id == :quick_actions))

    assert view |> element("#dashboard-tour") |> render() =~
             "data-total-steps=\"#{length(steps)}\""

    for anchor <- anchors(steps) do
      assert html =~ ~s(data-tour="#{anchor}"),
             "expected to find data-tour=\"#{anchor}\" in rendered /dashboard HTML"
    end
  end
end
