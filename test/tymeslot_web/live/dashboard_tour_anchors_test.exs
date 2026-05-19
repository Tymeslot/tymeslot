defmodule TymeslotWeb.DashboardTourAnchorsTest do
  @moduledoc false
  use TymeslotWeb.ConnCase, async: true

  @moduletag :live
  @moduletag :onboarding

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Onboarding.DashboardTour

  test "every non-nil step anchor resolves to a data-tour element on /dashboard", %{conn: conn} do
    user =
      insert(:user,
        onboarding_completed_at: DateTime.utc_now(:second),
        dashboard_tour_seen_at: nil
      )

    _profile = insert(:profile, user: user)

    {:ok, view, html} = live(log_in_user(conn, user), ~p"/dashboard")
    _ = view

    anchors =
      DashboardTour.steps()
      |> Enum.map(& &1.anchor)
      |> Enum.reject(&is_nil/1)

    for anchor <- anchors do
      assert html =~ ~s(data-tour="#{anchor}"),
             "expected to find data-tour=\"#{anchor}\" in rendered /dashboard HTML"
    end
  end
end
