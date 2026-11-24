defmodule TymeslotWeb.E2E.CalendarPhoneTest do
  @moduledoc """
  The calendar on a phone, in a real browser: the phone header, the tabs
  and the + button show instead of the desktop toolbar, nothing scrolls
  sideways, + opens the quick-create sheet and saves an event, a tap on the
  event opens its preview as a bottom sheet, the Month tab marks the day and
  lists the event under the grid, and the Agenda tab lists it.

  Only a browser sees the CSS that chooses the phone chrome and turns the
  popovers into sheets, so this is the one test of that layer. The calendar
  write is stubbed at the provider boundary (`Tymeslot.CalendarMock`).
  """

  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag :calendar

  alias Fluffy.Playwright.Keyboard
  alias Tymeslot.CalendarMock
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.TestMocks

  setup do
    TestMocks.stub_no_calendar_events()

    Mox.stub(CalendarMock, :create_event, fn event_data, _context ->
      {:ok, CreatedEvent.new(event_data.uid, provider_event_id: "g-" <> event_data.uid)}
    end)

    :ok
  end

  # An organiser with one writable Google calendar.
  defp organiser(session) do
    {session, user} = log_in_via_browser(session)

    {:ok, _prefs} =
      CalendarPreferencesQueries.upsert(user.id, %{time_format: "24h"})

    integration =
      insert(:calendar_integration,
        user: user,
        name: "Work account",
        provider: "google",
        is_active: true,
        calendar_list: [%{"id" => "work", "name" => "Work", "selected" => true}]
      )

    {session, integration}
  end

  defp read(session, script, args) do
    {session, evaluate_script(session, script, nil, args)}
  end

  # A bottom sheet spans the viewport's width and sits on its bottom edge.
  defp assert_bottom_sheet(session, selector) do
    # Measured once the sheet has slid fully into view.
    session = assert(session, in_viewport(by_css(selector), ratio: 1))

    {session, [left, right, bottom, width, height]} =
      read(
        session,
        """
        const r = document.querySelector(arg[0]).getBoundingClientRect();
        return [r.left, r.right, r.bottom, window.innerWidth, window.innerHeight];
        """,
        [selector]
      )

    assert left <= 1 and right >= width - 1,
           "#{selector} is not full width: #{left} to #{right} of #{width}"

    assert abs(bottom - height) <= 1,
           "#{selector} does not sit on the bottom edge: #{bottom} of #{height}"

    session
  end

  # A toast never sits under the + button, and its Undo stays a touch target
  # inside the toast and the viewport. Boxes are compared in the viewport;
  # the script returns what is wrong, so an empty list is the pass.
  defp assert_toast_clear_of_fab(session) do
    {session, problems} =
      read(
        session,
        """
        const box = (selector) => {
          const el = document.querySelector(selector);
          if (!el) return null;
          const r = el.getBoundingClientRect();
          return { l: r.left, t: r.top, r: r.right, b: r.bottom };
        };
        const toast = box("#calendar-toast"), fab = box("#calendar-fab"), undo = box("#calendar-undo");
        if (!toast || !fab || !undo) return ["the toast, the + button and Undo should all be on screen"];
        const problems = [];
        if (toast.r > fab.l && toast.l < fab.r && toast.b > fab.t && toast.t < fab.b)
          problems.push("the toast overlaps the + button");
        if (undo.r - undo.l < 44 || undo.b - undo.t < 44) problems.push("Undo is smaller than 44px");
        if (undo.l < toast.l || undo.r > toast.r || undo.t < toast.t || undo.b > toast.b)
          problems.push("Undo falls outside the toast");
        if (toast.l < 0 || toast.r > window.innerWidth) problems.push("the toast runs off the screen");
        return problems;
        """,
        []
      )

    assert problems == [], Enum.join(problems, "; ")

    session
  end

  # A busy month cell carries dots (`.cal-month-dot`, Task 2); a quiet one none.
  defp assert_marked(session, busy, quiet) do
    {session, [busy_count, quiet_count]} =
      read(
        session,
        """
        const count = (iso) => document.querySelectorAll(`button[data-month-day="${iso}"] .cal-month-dot`).length;
        return [count(arg[0]), count(arg[1])];
        """,
        [busy, quiet]
      )

    assert busy_count > 0 and quiet_count == 0,
           "#{busy} should carry dots and #{quiet} none (#{busy_count} vs #{quiet_count})"

    session
  end

  @tag Playwright.Test.use(viewport: %{width: 390, height: 844})
  test "on a phone, + adds an event that opens as a sheet and shows in month and agenda", %{
    session: session
  } do
    # Ten days past this month's end: always ahead, and with the day, the day
    # after and the one after that in the same month (a tap on the next day
    # must not move the month grid).
    day = Date.utc_today() |> Date.end_of_month() |> Date.add(10)
    iso = Date.to_iso8601(day)
    next = Date.to_iso8601(Date.add(day, 1))
    after_next = Date.to_iso8601(Date.add(day, 2))

    {session, _integration} = organiser(session)

    session
    |> visit("/dashboard/calendar?view=day&date=#{iso}")
    |> assert_has(by_css("#calendar-canvas[aria-busy='false']"))
    # The phone chrome, not the desktop toolbar.
    |> assert_has(by_css("#calendar-phone-header"))
    |> assert_has(by_css("#calendar-tabs"))
    |> assert_has(by_css("#calendar-fab"))
    |> refute_has(by_css("#calendar-toolbar"))
    |> assert_has(by_css("#calendar-tab-day[aria-current='page']"))
    |> assert_no_horizontal_overflow("calendar, Day view at 390px")
    # + opens quick create as a sheet; a title and Save create the event.
    |> click(by_css("#calendar-fab"))
    |> assert_has(by_css("#calendar-quick-create.is-sheet"))
    |> assert_bottom_sheet("#calendar-quick-create")
    |> fill(by_css("#calendar-qc-field"), "Dentist")
    |> click(by_css("#calendar-quick-create [data-qc-save]"))
    |> assert_has(filter(by_css("#calendar-toast"), has_text: "Added"))
    |> assert_has(by_css("#calendar-undo"))
    |> assert_toast_clear_of_fab()
    |> assert_has(filter(by_css(".cal-col .cal-ev"), has_text: "Dentist"))
    # A tap on it opens the preview as a bottom sheet.
    |> click(filter(by_css(".cal-col .cal-ev"), has_text: "Dentist"))
    |> assert_has(filter(by_css("#calendar-preview"), has_text: "Dentist"))
    |> assert_bottom_sheet("#calendar-preview")
    |> Keyboard.press("Escape")
    |> refute_has(by_css("#calendar-preview"))
    # Month: the selected day's agenda lists it under the grid.
    |> click(by_css("#calendar-tab-month"))
    |> assert_has(by_css("#calendar-tab-month[aria-current='page']"))
    |> assert(count(filter(by_css("button[data-month-day]"), visible: true), 42))
    |> assert_has(filter(by_css("#calendar-canvas [data-event-id]"), has_text: "Dentist"))
    |> assert_no_horizontal_overflow("calendar, Month view at 390px")
    # Select the next day, so the event's day is an ordinary cell: it has dots.
    |> click(by_css("button[data-month-day='#{next}']"))
    |> assert(
      count(
        filter(by_css("#calendar-canvas [data-event-id]"), has_text: "Dentist", visible: true),
        0
      )
    )
    |> assert_marked(iso, after_next)
    |> click(by_css("button[data-month-day='#{iso}']"))
    |> assert_has(filter(by_css("#calendar-canvas [data-event-id]"), has_text: "Dentist"))
    # Agenda from that day lists it.
    |> click(by_css("#calendar-tab-agenda"))
    |> assert_has(by_css("#calendar-tab-agenda[aria-current='page']"))
    |> assert_has(filter(by_css("#calendar-canvas [data-event-id]"), has_text: "Dentist"))
    |> assert_no_horizontal_overflow("calendar, Agenda view at 390px")
  end

  @tag Playwright.Test.use(viewport: TymeslotWeb.E2EHelpers.mobile_viewport())
  test "the phone calendar fits the narrowest supported viewport in every tab", %{
    session: session
  } do
    {session, _integration} = organiser(session)

    session =
      session
      |> visit("/dashboard/calendar")
      |> assert_has(by_css("#calendar-canvas[aria-busy='false']"))
      # The stored default is a week, which a phone shows as 3 days.
      |> assert_has(by_css("#calendar-tab-three_day[aria-current='page']"))
      |> assert_has(by_css("#calendar-canvas[data-view='three_day']"))
      |> assert_no_horizontal_overflow("calendar, 3 days at 320px")

    # Each tab waits for what only its own view draws.
    for {tab, drawn} <- [
          {"agenda", &assert_has(&1, by_css("#calendar-canvas .cal-agenda"))},
          {"day",
           &assert_has(
             &1,
             by_css("#calendar-canvas .cal-col") |> filter(visible: true) |> first()
           )},
          {"month",
           &assert(&1, count(filter(by_css("button[data-month-day]"), visible: true), 42))}
        ] do
      session
      |> click(by_css("#calendar-tab-#{tab}"))
      |> assert_has(by_css("#calendar-tab-#{tab}[aria-current='page']"))
      |> assert_has(by_css("#calendar-canvas[aria-busy='false']"))
      |> then(drawn)
      |> assert_no_horizontal_overflow("calendar, #{tab} at 320px")
    end
  end

  @tag Playwright.Test.use(viewport: %{width: 390, height: 844})
  test "the agenda loads further weeks as it is scrolled, and the Calendars sheet is a bottom sheet",
       %{session: session} do
    {session, integration} = organiser(session)
    # Past the first window (eight weeks ahead), inside the next chunk.
    far = Date.add(Date.utc_today(), 70)

    insert(:provider_calendar_event,
      calendar_integration: integration,
      provider: "google",
      provider_calendar_id: "work",
      summary: "Far trip",
      start_at: DateTime.new!(far, ~T[10:00:00], "Etc/UTC"),
      end_at: DateTime.new!(far, ~T[11:00:00], "Etc/UTC"),
      all_day: false,
      sync_state: "synced"
    )

    session
    |> visit("/dashboard/calendar?view=agenda")
    |> assert_has(by_css("#calendar-canvas[aria-busy='false']"))
    |> assert_has(by_css("#calendar-canvas .cal-agenda"))
    |> tap(
      &evaluate_script(&1, """
      const scroller = document.querySelector('#calendar-canvas [data-view-scroll]');
      scroller.scrollTop = scroller.scrollHeight;
      """)
    )
    |> assert_has(filter(by_css("#calendar-canvas [data-event-id]"), has_text: "Far trip"))
    |> click(by_css("#calendar-phone-calendars"))
    |> assert_has(by_css("#calendar-calendars-sheet[style*='display: flex']"))
    |> assert_bottom_sheet("#calendar-calendars-sheet .modal-content")
  end
end
