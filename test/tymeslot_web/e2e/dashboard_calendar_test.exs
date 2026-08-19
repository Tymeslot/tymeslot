defmodule TymeslotWeb.E2E.DashboardCalendarTest do
  use TymeslotWeb.BrowserCase, async: false

  alias Tymeslot.Factory

  @moduletag :e2e
  @moduletag :calendar

  # These browser tests exercise JS hook + LiveView server round-trips that
  # unit tests can't reach: the CalendarCreate drag hook, the inline edit
  # click handler, and the modal DOM wiring. They deliberately stop short of
  # the full Task-based save path — that is covered by the LiveView tests in
  # events_rendering_test.exs, which send the result message directly to
  # bypass provider-layer HTTP. Here we assert on the immediate optimistic
  # state, which is what regresses when hooks or modal templates break.

  feature "user can open the create-event modal via the grid drag hook", %{
    session: session
  } do
    {session, user} = log_in_via_browser(session)
    _integration = Factory.insert(:calendar_integration, user: user, is_active: true)

    session
    |> visit("/dashboard/calendar")
    |> wait_for_live()
    |> assert_has(css("#calendar-create-zone"))
    |> simulate_grid_drag()
    |> assert_has(css("#create-event-modal"))
    |> assert_has(css("#create-event-title"))
  end

  feature "user can rename an event inline from the detail modal", %{session: session} do
    {session, user} = log_in_via_browser(session)
    integration = Factory.insert(:calendar_integration, user: user, is_active: true)

    today = Date.utc_today()

    event =
      Factory.insert(:provider_calendar_event, %{
        calendar_integration: integration,
        summary: "Original Title",
        start_at: DateTime.new!(today, ~T[10:00:00], "Etc/UTC"),
        end_at: DateTime.new!(today, ~T[11:00:00], "Etc/UTC"),
        all_day: false
      })

    session
    |> visit("/dashboard/calendar")
    |> wait_for_live()
    |> assert_has(css("[data-event-id='#{event.id}']", text: "Original Title"))
    |> execute_script("document.querySelector(\"[data-event-id='#{event.id}']\").click()")
    |> assert_has(css("#event-title-input"))
    # Wallaby's fill_in types one key at a time, which keeps resetting the
    # input's phx-debounce=500 timer; the test then races the debounce.
    # Setting value directly and dispatching a single input event makes the
    # debounce fire exactly once and keeps the assertion timing reliable.
    |> execute_script("""
      const input = document.getElementById('event-title-input');
      input.focus();
      input.setSelectionRange(0, input.value.length);
      input.value = 'Renamed In Browser';
      input.dispatchEvent(new Event('input', {bubbles: true}));
    """)
    |> assert_has(css("[data-event-id='#{event.id}']", text: "Renamed In Browser"))
  end

  # The grid is the widest thing in the dashboard and demotes to a narrower view
  # on small screens, so it is the most likely place for the shell to be pushed
  # past the viewport.
  feature "calendar grid fits the narrowest supported viewport", %{session: session} do
    {session, user} = log_in_via_browser(session)
    _integration = Factory.insert(:calendar_integration, user: user, is_active: true)

    session
    |> resize_to_mobile()
    |> visit("/dashboard/calendar")
    |> wait_for_live()
    |> assert_has(css("[data-day-col]", count: :any, minimum: 1))
    |> assert_no_horizontal_overflow("dashboard calendar at 320px")
  end

  # Drag-to-create uses real mousedown/mousemove/mouseup events on an empty
  # day column. We dispatch synthetic MouseEvents via execute_script rather
  # than using Wallaby's cursor API because the CalendarCreate hook snaps
  # coordinates to the grid geometry, which we can compute reliably from the
  # column's bounding rect.
  defp simulate_grid_drag(session) do
    execute_script(session, """
    const col = document.querySelector('[data-day-col]');
    if (!col) { throw new Error('no data-day-col found'); }
    const rect = col.getBoundingClientRect();
    const x = rect.left + Math.floor(rect.width / 2);
    const y = rect.top + 100;
    const base = { bubbles: true, cancelable: true, view: window, button: 0 };
    col.dispatchEvent(new MouseEvent('mousedown', { ...base, clientX: x, clientY: y }));
    document.dispatchEvent(new MouseEvent('mousemove', { ...base, clientX: x, clientY: y + 30 }));
    document.dispatchEvent(new MouseEvent('mouseup',   { ...base, clientX: x, clientY: y + 30 }));
    """)

    session
  end
end
