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
  # exercise that branching end-to-end through ChromeDriver.

  feature "desktop viewport: tour appears, Next advances the step, Skip dismisses",
          %{session: session} do
    session = resize_window(session, 1280, 800)

    {session, user} =
      log_in_via_browser(session, %{dashboard_tour_seen_at: nil})

    session
    |> assert_has(css("#dashboard-tour"))
    |> assert_has(css("#dashboard-tour[data-step-index='0']"))
    |> click(button("Next"))
    |> assert_has(css("#dashboard-tour[data-step-index='1']"))
    |> click(button("Skip"))
    |> assert_tour_removed()

    assert %DateTime{} = Repo.reload!(user).dashboard_tour_seen_at
  end

  feature "mobile viewport: hook reports too small, overlay is dismissed without marking seen",
          %{session: session} do
    session = resize_window(session, 390, 844)

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
  # fades it out before dropping it from the DOM. `refute_has/2` is not a waiter
  # — it retries only until an element *appears*, and so fires mid-fade while the
  # overlay is still there. A `count: 0` query retries until the element is gone,
  # and `visible: :any` ignores both the fade and the sub-1024px `display: none`.
  defp assert_tour_removed(session) do
    assert_has(session, css("#dashboard-tour", count: 0, visible: :any))
  end
end
