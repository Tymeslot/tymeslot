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
    |> refute_has(css("#dashboard-tour"))

    assert %DateTime{} = Repo.reload!(user).dashboard_tour_seen_at
  end

  feature "mobile viewport: hook reports too small, overlay is dismissed without marking seen",
          %{session: session} do
    session = resize_window(session, 390, 844)

    {session, user} =
      log_in_via_browser(session, %{dashboard_tour_seen_at: nil})

    # The tour briefly renders on the initial LiveView response (the server
    # doesn't know the viewport yet) and is removed once the hook fires
    # `tour:viewport-too-small`. refute_has retries until the element is gone.
    refute_has(session, css("#dashboard-tour"))

    # The seen flag is intentionally NOT persisted on a too-small viewport, so
    # the user still gets the tour on their next desktop visit.
    assert is_nil(Repo.reload!(user).dashboard_tour_seen_at)
  end
end
