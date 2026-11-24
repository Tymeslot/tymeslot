defmodule TymeslotWeb.E2E.DashboardTourTest do
  use TymeslotWeb.BrowserCase, async: false

  alias Tymeslot.Repo

  @moduletag :e2e
  @moduletag :onboarding

  # The tour overlay only mounts when the viewport is at least 1024px wide
  # (matched by the DashboardTour JS hook). On narrower viewports the hook
  # pushes `tour:viewport-too-small`, which dismisses the overlay *without*
  # marking the user seen — so a mobile visitor still gets the tour the next
  # time they open the dashboard on a large enough screen. These two scenarios
  # exercise that branching end-to-end in a real browser.

  test "desktop viewport: tour appears, Next advances the step, Skip dismisses",
       %{session: session} do
    session = set_viewport_size(session, %{width: 1280, height: 800})

    {session, user} =
      log_in_via_browser(session, %{dashboard_tour_seen_at: nil})

    session
    |> assert_has(by_css("#dashboard-tour"))
    |> assert_has(by_css("#dashboard-tour[data-step-index='0']"))
    |> click(by_role(:button, name: "Next", exact: true))
    |> assert_has(by_css("#dashboard-tour[data-step-index='1']"))
    |> click(by_role(:button, name: "Skip"))
    |> assert_tour_removed()

    assert %DateTime{} = Repo.reload!(user).dashboard_tour_seen_at
  end

  test "mobile viewport: hook reports too small, overlay is dismissed without marking seen",
       %{session: session} do
    session = set_viewport_size(session, %{width: 390, height: 844})

    {session, user} =
      log_in_via_browser(session, %{dashboard_tour_seen_at: nil})

    # The tour briefly renders on the initial LiveView response (the server
    # doesn't know the viewport yet) and is removed once the hook fires
    # `tour:viewport-too-small`. Below 1024px the overlay is also hidden in CSS,
    # so asserting on *visibility* would pass even if the hook never ran —
    # assert_tour_removed/1 waits for it to actually leave the DOM.
    assert_tour_removed(session)

    # The seen flag is intentionally NOT persisted on a too-small viewport, so
    # the user still gets the tour on their next desktop visit.
    assert is_nil(Repo.reload!(user).dashboard_tour_seen_at)
  end

  # The overlay carries `phx-remove={JS.transition(..., time: 700)}`, so LiveView
  # fades it out before dropping it from the DOM. A count of 0 retries until the
  # element is gone, ignoring both the fade and the sub-1024px `display: none`.
  defp assert_tour_removed(session) do
    assert(session, count(by_css("#dashboard-tour"), 0))
  end
end
