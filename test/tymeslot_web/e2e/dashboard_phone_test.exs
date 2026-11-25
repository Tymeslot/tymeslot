defmodule TymeslotWeb.E2E.DashboardPhoneTest do
  @moduledoc """
  The dashboard on the narrowest phone the design system targets (320px):
  every section the sidebar links to fits the screen with nothing past its
  right edge, and the off-canvas sidebar opens from the menu button, takes
  the host to a section and closes, by a link, by its close button and by
  Escape.

  The calendar and meeting settings have phone checks of their own
  (`CalendarPhoneTest`, `CreateEventTypeTest`), but through
  `E2EHelpers.assert_no_horizontal_overflow/2`; this test measures every
  section with the same `E2EHelpers.overflow_culprits/1`, so they are listed
  here too. Account settings is not in the sidebar and has no shell
  (`AccountSettingsTest` covers it). The account
  holds a little of everything a section lists (a meeting type, a calendar,
  a video integration, an upcoming meeting, a poll, a venue, a webhook), so
  the sections are measured with their rows drawn, not only their empty
  states.
  """
  use TymeslotWeb.BrowserCase, async: false

  alias Tymeslot.TestHelpers.Eventually

  @moduletag :e2e
  @moduletag :dashboard

  @width 320
  @height 844

  # Every section the sidebar links to, by the path its nav link patches to.
  @sections [
    {"overview", "/dashboard/overview"},
    {"calendar", "/dashboard"},
    {"meetings", "/dashboard/meetings"},
    {"analytics", "/dashboard/analytics"},
    {"meeting settings", "/dashboard/meeting-settings"},
    {"locations", "/dashboard/locations"},
    {"availability", "/dashboard/availability"},
    {"polls", "/dashboard/polls"},
    {"booking pages", "/dashboard/pages"},
    {"languages", "/dashboard/languages"},
    {"integrations", "/dashboard/integrations"},
    {"embed", "/dashboard/embed"},
    {"settings", "/dashboard/settings"},
    {"automation", "/dashboard/automation"}
  ]

  # Sub-pixel rounding in the WebDriver bridge can put a rect one px over.
  @tolerance 1

  feature "every dashboard section fits a 320px screen", %{session: session} do
    {session, user} = log_in_at_phone_width(session)
    seed_rows(user)

    # Each section is loaded afresh at this width (rather than patched to),
    # so nothing is measured mid-transition from the previous layout. Every
    # section is measured before failing, so one run names them all.
    overflowing =
      Enum.flat_map(@sections, fn {name, path} ->
        case section_overflow(session, path) do
          [] -> []
          culprits -> ["#{name} (#{path}):\n" <> Enum.map_join(culprits, "\n", &"    - #{&1}")]
        end
      end)

    assert overflowing == [],
           "Horizontal overflow at #{@width}px:\n\n  " <> Enum.join(overflowing, "\n  ")
  end

  feature "the mobile sidebar opens, navigates to a section and closes", %{session: session} do
    {session, _user} = log_in_at_phone_width(session)

    session =
      session
      |> visit("/dashboard/overview")
      |> wait_for_dashboard()
      |> assert_sidebar_closed()
      |> open_sidebar()

    # Open, the drawer lies wholly on screen, with the backdrop beside it.
    assert sidebar_rect(session)["right"] <= @width + @tolerance
    assert overflow_culprits(session) == []

    # A nav link takes the host to its section and the drawer closes behind
    # it, without the focus being handed back to the menu button.
    session =
      session
      |> click(css("#dashboard-sidebar a[href='/dashboard/availability']"))
      |> assert_has(
        css("#dashboard-sidebar a[href='/dashboard/availability'][aria-current='page']",
          visible: :any
        )
      )
      |> assert_sidebar_closed()

    assert current_path(session) == "/dashboard/availability"

    # The close button, then Escape: both close the drawer and hand the focus
    # back to the menu button that opened it.
    session
    |> open_sidebar()
    |> click(css("#dashboard-sidebar button[aria-label='Close sidebar']"))
    |> assert_sidebar_closed()
    |> assert_focus_on_toggle()
    |> open_sidebar()
    |> send_keys([:escape])
    |> assert_sidebar_closed()
    |> assert_focus_on_toggle()
  end

  # ── Setup ──────────────────────────────────────────────────────────────

  defp log_in_at_phone_width(session) do
    session
    |> resize_window(@width, @height)
    |> log_in_via_browser(%{dashboard_tour_seen_at: DateTime.utc_now(:second)})
  end

  defp seed_rows(user) do
    insert(:calendar_integration, user: user, user_id: user.id)
    insert(:video_integration, user: user, user_id: user.id)
    insert(:future_meeting, organizer_user: user, organizer_user_id: user.id)
    insert(:poll, user: user, user_id: user.id, title: "Quarterly planning with the whole team")
    insert(:venue, user: user, user_id: user.id, name: "Riverside office, second floor")
    insert(:webhook, user: user, user_id: user.id)
  end

  # ── Sections ───────────────────────────────────────────────────────────

  # Loads `path` and returns what overflows it. The section has rendered once
  # its own nav link is the current one (the sidebar is closed at this width,
  # so the link is looked for whether shown or not) and the LiveView has
  # connected.
  defp section_overflow(session, path) do
    session
    |> visit(path)
    |> wait_for_dashboard()
    |> assert_has(css("#dashboard-sidebar a[href='#{path}'][aria-current='page']", visible: :any))
    |> overflow_culprits()
  end

  # ── Sidebar ────────────────────────────────────────────────────────────

  # Opens the drawer and waits for its slide-in to finish, so a click that
  # follows lands where the link is drawn rather than where it was mid-slide.
  defp open_sidebar(session) do
    session =
      session
      |> click(css("#dashboard-sidebar-toggle[aria-expanded='false']"))
      |> assert_has(css("#dashboard-sidebar.dashboard-sidebar-open"))
      |> assert_has(css("#dashboard-sidebar-toggle[aria-expanded='true']"))
      |> assert_has(css("#dashboard-sidebar-overlay:not(.hidden)"))

    Eventually.eventually(fn -> abs(sidebar_rect(session)["left"]) <= @tolerance end,
      timeout: 3_000,
      message: "the sidebar did not finish sliding in"
    )

    session
  end

  # Closed: the class gone, the backdrop hidden, the toggle collapsed, and the
  # drawer slid off screen to the left once its transition has run.
  defp assert_sidebar_closed(session) do
    session =
      session
      |> assert_has(css("#dashboard-sidebar:not(.dashboard-sidebar-open)", visible: :any))
      |> assert_has(css("#dashboard-sidebar-overlay.hidden", visible: :any))
      |> assert_has(css("#dashboard-sidebar-toggle[aria-expanded='false']"))
      |> assert_has(css("#dashboard-sidebar", visible: false))

    assert sidebar_rect(session)["right"] <= @tolerance
    session
  end

  defp assert_focus_on_toggle(session) do
    Eventually.eventually(
      fn ->
        evaluate_script(
          session,
          "return document.activeElement && document.activeElement.id === 'dashboard-sidebar-toggle';"
        )
      end,
      timeout: 3_000,
      message: "the focus did not return to the menu button"
    )

    session
  end

  defp sidebar_rect(session) do
    evaluate_script(session, """
    const rect = document.getElementById("dashboard-sidebar").getBoundingClientRect();
    return {left: rect.left, right: rect.right};
    """)
  end
end
