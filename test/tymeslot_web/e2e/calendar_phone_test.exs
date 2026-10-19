defmodule TymeslotWeb.E2E.CalendarPhoneTest do
  @moduledoc """
  The new calendar on a phone, in a real browser: the phone header, the tabs
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

  # An organiser on the new calendar with one writable Google calendar.
  defp organiser(session) do
    {session, user} = log_in_via_browser(session)

    {:ok, _prefs} =
      CalendarPreferencesQueries.upsert(user.id, %{redesign_enabled: true, time_format: "24h"})

    insert(:calendar_integration,
      user: user,
      name: "Work account",
      provider: "google",
      is_active: true,
      calendar_list: [%{"id" => "work", "name" => "Work", "selected" => true}]
    )

    session
  end

  defp read(session, script, args) do
    me = self()
    ref = make_ref()

    session =
      execute_script(session, script, args, fn result -> send(me, {:read, ref, result}) end)

    assert_receive {:read, ^ref, result}, 5_000
    {session, result}
  end

  # A bottom sheet spans the viewport's width and sits on its bottom edge.
  defp assert_bottom_sheet(session, selector) do
    {session, [left, right, bottom, width, height]} =
      read(
        session,
        """
        const r = document.querySelector(arguments[0]).getBoundingClientRect();
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

  # A busy month cell carries dots (`.cal-month-dot`, Task 2); a quiet one none.
  defp assert_marked(session, busy, quiet) do
    {session, [busy_count, quiet_count]} =
      read(
        session,
        """
        const count = (iso) => document.querySelectorAll(`button[data-month-day="${iso}"] .cal-month-dot`).length;
        return [count(arguments[0]), count(arguments[1])];
        """,
        [busy, quiet]
      )

    assert busy_count > 0 and quiet_count == 0,
           "#{busy} should carry dots and #{quiet} none (#{busy_count} vs #{quiet_count})"

    session
  end

  feature "on a phone, + adds an event that opens as a sheet and shows in month and agenda", %{
    session: session
  } do
    day = Date.add(Date.utc_today(), 7)
    iso = Date.to_iso8601(day)
    next = Date.to_iso8601(Date.add(day, 1))
    after_next = Date.to_iso8601(Date.add(day, 2))

    session
    |> organiser()
    |> resize_window(390, 844)
    |> visit("/dashboard/calendar?view=day&date=#{iso}")
    |> wait_for_live()
    |> assert_has(css("#calendar-canvas[aria-busy='false']"))
    # The phone chrome, not the desktop toolbar.
    |> assert_has(css("#calendar-phone-header"))
    |> assert_has(css("#calendar-tabs"))
    |> assert_has(css("#calendar-fab"))
    |> refute_has(css("#calendar-toolbar"))
    |> assert_has(css("#calendar-tab-day[aria-current='page']"))
    |> assert_no_horizontal_overflow("new calendar, Day view at 390px")
    # + opens quick create as a sheet; a title and Save create the event.
    |> click(css("#calendar-fab"))
    |> assert_has(css("#calendar-quick-create.is-sheet"))
    |> assert_bottom_sheet("#calendar-quick-create")
    |> fill_in(css("#calendar-qc-field"), with: "Dentist")
    |> click(css("#calendar-quick-create [data-qc-save]"))
    |> assert_has(css("#calendar-toast", text: "Added"))
    |> assert_has(css(".cal-col .cal-ev", text: "Dentist"))
    # A tap on it opens the preview as a bottom sheet.
    |> click(css(".cal-col .cal-ev", text: "Dentist"))
    |> assert_has(css("#calendar-preview", text: "Dentist"))
    |> assert_bottom_sheet("#calendar-preview")
    |> send_keys([:escape])
    |> refute_has(css("#calendar-preview"))
    # Month: the selected day's agenda lists it under the grid.
    |> click(css("#calendar-tab-month"))
    |> assert_has(css("#calendar-tab-month[aria-current='page']"))
    |> assert_has(css("button[data-month-day]", count: 42))
    |> assert_has(css("#calendar-canvas [data-event-id]", text: "Dentist"))
    |> assert_no_horizontal_overflow("new calendar, Month view at 390px")
    # Select the next day, so the event's day is an ordinary cell: it has dots.
    |> click(css("button[data-month-day='#{next}']"))
    |> refute_has(css("#calendar-canvas [data-event-id]", text: "Dentist"))
    |> assert_marked(iso, after_next)
    |> click(css("button[data-month-day='#{iso}']"))
    |> assert_has(css("#calendar-canvas [data-event-id]", text: "Dentist"))
    # Agenda from that day lists it.
    |> click(css("#calendar-tab-agenda"))
    |> assert_has(css("#calendar-tab-agenda[aria-current='page']"))
    |> assert_has(css("#calendar-canvas [data-event-id]", text: "Dentist"))
    |> assert_no_horizontal_overflow("new calendar, Agenda view at 390px")
  end

  feature "the phone calendar fits the narrowest supported viewport in every tab", %{
    session: session
  } do
    session =
      session
      |> organiser()
      |> resize_to_mobile()
      |> visit("/dashboard/calendar")
      |> wait_for_live()
      |> assert_has(css("#calendar-canvas[aria-busy='false']"))
      |> assert_no_horizontal_overflow("new calendar, 3 days at 320px")

    for tab <- ~w(agenda day month) do
      session
      |> click(css("#calendar-tab-#{tab}"))
      |> assert_has(css("#calendar-tab-#{tab}[aria-current='page']"))
      |> assert_has(css("#calendar-canvas[aria-busy='false']"))
      |> assert_no_horizontal_overflow("new calendar, #{tab} at 320px")
    end
  end
end
