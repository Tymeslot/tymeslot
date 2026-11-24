defmodule TymeslotWeb.E2E.CalendarPowerTest do
  @moduledoc """
  The calendar's power layer in a real browser at 1280x800: Ctrl K
  searches, and choosing an event that is folded into a "+N" chip two weeks
  ahead moves there and opens its preview; a typed line ("tomorrow 10:00
  Dentist") becomes quick create, filled in, and Enter saves it; 1 applies
  a seeded calendar set and the chip names it, 0 leaves it; F hides the
  dashboard menu and the toolbar's control brings it back; ? opens the
  shortcut help and Esc closes it.

  Only a browser runs the hook's keys, the reveal and the focus-mode CSS
  together, so this is the one test of that layer. The calendar write is
  stubbed at the provider boundary (`Tymeslot.CalendarMock`).
  """

  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag Playwright.Test.use(viewport: %{width: 1280, height: 800})
  @moduletag :calendar

  alias Fluffy.Playwright.Keyboard
  alias Tymeslot.CalendarGrid.CalendarSets
  alias Tymeslot.CalendarMock
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Profiles
  alias Tymeslot.TestMocks

  setup do
    TestMocks.stub_no_calendar_events()
    test_pid = self()

    Mox.stub(CalendarMock, :create_event, fn event_data, _context ->
      send(test_pid, {:created, event_data})
      {:ok, CreatedEvent.new(event_data.uid, provider_event_id: "g-" <> event_data.uid)}
    end)

    :ok
  end

  # An organiser on the calendar, zone UTC (so "tomorrow" agrees with
  # `Date.utc_today/0`), tour already seen (a running tour suspends focus
  # mode), with a Google account holding "Work" and "Family".
  defp organiser(session) do
    {session, user} =
      log_in(session, %{dashboard_tour_seen_at: DateTime.utc_now(:second)})

    {:ok, profile} = Profiles.get_or_create_profile(user.id)
    {:ok, _profile} = Profiles.update_timezone(profile, "Etc/UTC")

    {:ok, _prefs} =
      CalendarPreferencesQueries.upsert(user.id, %{
        time_format: "24h",
        default_view: "week"
      })

    integration =
      insert(:calendar_integration,
        user: user,
        name: "Work account",
        provider: "google",
        is_active: true,
        calendar_list: [
          %{"id" => "work", "name" => "Work", "selected" => true},
          %{"id" => "family", "name" => "Family", "selected" => true}
        ]
      )

    {session, user, integration}
  end

  defp timed(integration, calendar, title, %DateTime{} = start_at, minutes) do
    insert(:provider_calendar_event,
      calendar_integration: integration,
      provider: "google",
      provider_calendar_id: calendar,
      summary: title,
      start_at: start_at,
      end_at: DateTime.add(start_at, minutes, :minute),
      all_day: false,
      sync_state: "synced"
    )
  end

  # Single keys reach the hook's document listener only when no field has
  # focus, as when the organiser has clicked on the grid.
  defp blur(session) do
    evaluate_script(session, "document.activeElement && document.activeElement.blur();")
    session
  end

  defp ctrl_k(session), do: Keyboard.press(session, "Control+k")

  defp open_calendar(session, query) do
    session
    |> visit("/dashboard/calendar#{query}")
    |> assert_has(by_css("#calendar-canvas[aria-busy='false']"))
  end

  test "Ctrl K reveals an event folded into +N, and a typed line adds an event", %{
    session: session
  } do
    {session, _user, integration} = organiser(session)

    # Six meetings at once two weeks ahead: the shortest ranks last, so it
    # folds into the column's "+N" chip at this width.
    crowded = Date.add(Date.utc_today(), 14)
    iso = Date.to_iso8601(crowded)
    at_ten = DateTime.new!(crowded, ~T[10:00:00], "Etc/UTC")
    for n <- 1..5, do: timed(integration, "work", "Interview #{n}", at_ten, 90)
    timed(integration, "work", "Quarterly sync", at_ten, 45)

    tomorrow = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()

    session =
      session
      |> open_calendar("?view=week")
      |> refute_has(by_css(".cal-col[data-day='#{iso}']"))
      # Search, and Enter on the first result.
      |> ctrl_k()
      |> assert_has(by_css("#calendar-command[data-open]"))
      |> fill(by_css("#calendar-command-input"), "Quarterly")
      |> assert_has(
        filter(by_css("#calendar-command-results [data-command-result][data-date='#{iso}']"),
          has_text: "Quarterly sync"
        )
      )
      |> Keyboard.press("Enter")
      |> refute_has(by_css("#calendar-command[data-open]"))
      # The week moved there, the event is still folded, and its preview is open.
      |> assert_has(by_css(".cal-col[data-day='#{iso}'] .cal-more"))
      |> refute_has(
        filter(by_css(".cal-col[data-day='#{iso}'] .cal-ev"), has_text: "Quarterly sync")
      )
      |> assert_has(filter(by_css("#calendar-preview"), has_text: "Quarterly sync"))

    session =
      session
      |> assert(page_url(~r/date=#{iso}/))
      |> Keyboard.press("Escape")
      |> refute_has(by_css("#calendar-preview"))
      # Add by typing: the "Add" row goes first because the line has a time.
      |> ctrl_k()
      |> assert_has(by_css("#calendar-command[data-open]"))
      |> fill(by_css("#calendar-command-input"), "tomorrow 10:00 Dentist")
      |> assert_has(
        filter(by_css("#calendar-command-instant [data-command-row='add']"), has_text: "Dentist")
      )
      |> Keyboard.press("Enter")
      |> refute_has(by_css("#calendar-command[data-open]"))
      |> assert_has(by_css("#calendar-quick-create"))
      |> Keyboard.press("Enter")
      |> assert_has(filter(by_css("#calendar-toast"), has_text: "Added"))

    assert_receive {:created, %{summary: "Dentist"}}, 5_000

    session
    |> open_calendar("?view=day&date=#{tomorrow}")
    |> assert_has(filter(by_css(".cal-col[data-day='#{tomorrow}'] .cal-ev"), has_text: "Dentist"))
  end

  test "digits switch calendar sets, F toggles focus mode and ? opens the shortcuts", %{
    session: session
  } do
    {session, user, integration} = organiser(session)

    {:ok, _set} =
      CalendarSets.create(user.id, "Work", [
        %{integration_id: integration.id, calendar_id: "work"}
      ])

    session
    |> open_calendar("?view=week")
    |> refute_has(by_css("#calendar-filter-chip"))
    # 1 applies the set: the chip names it while it is active, rail open or not.
    |> blur()
    |> Keyboard.type("1")
    |> assert_has(filter(by_css("#calendar-filter-chip"), has_text: "Work set"))
    |> assert_has(by_css("#calendar-rail-set-1[aria-pressed='true']"))
    # 0 leaves it; nothing else was hidden, so the chip goes.
    |> Keyboard.type("0")
    |> refute_has(by_css("#calendar-filter-chip"))
    |> assert_has(by_css("#calendar-rail-set-0[aria-pressed='true']"))
    # F hides the dashboard menu; the toolbar's control brings it back.
    |> assert_has(by_css("#dashboard-sidebar"))
    |> Keyboard.type("f")
    |> assert_has(by_css("#dashboard-root[data-calendar-focus]"))
    |> refute_has(by_css("#dashboard-sidebar"))
    |> click(by_css("#calendar-focus-toggle[aria-pressed='true']"))
    |> refute_has(by_css("#dashboard-root[data-calendar-focus]"))
    |> assert_has(by_css("#dashboard-sidebar"))
    # ? opens the shortcut help; Esc closes it.
    |> blur()
    |> Keyboard.type("?")
    |> assert_has(
      filter(by_css("#calendar-shortcuts"), has_text: "Search and commands (Cmd K on a Mac)")
    )
    |> Keyboard.press("Escape")
    |> refute_has(by_css("#calendar-shortcuts"))
  end
end
