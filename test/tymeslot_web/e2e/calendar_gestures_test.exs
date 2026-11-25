defmodule TymeslotWeb.E2E.CalendarGesturesTest do
  @moduledoc """
  The calendar canvas's pointer, wheel and touch gestures in a real browser:
  a drag on an event's bottom grip resizes it and saves the new end; Ctrl
  with the wheel (a trackpad pinch reports the same) zooms the hours; on a
  phone, a sideways swipe steps the day, a long-press picks an event up and
  moves it, and two fingers spreading over the grid zoom the hours.

  Only a browser runs the hook's gesture handling, so each gesture is
  dispatched as the events the hook listens to (synthetic `PointerEvent`s
  and `WheelEvent`s, since Wallaby has no native gesture), never as the
  LiveView event it ends in. A synthetic pointer cannot be captured, so the
  canvas's pointer capture is replaced with a no-op. Calendar writes are
  stubbed at the provider boundary (`Tymeslot.CalendarMock`).
  """

  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag :calendar

  import Tymeslot.TestHelpers.Eventually

  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  # The comfortable density's hour height (assets/js/calendar/time.js).
  @hour_px 52

  @pointer """
  const canvas = document.getElementById('calendar-canvas');
  canvas.setPointerCapture = () => {};
  canvas.releasePointerCapture = () => {};
  const send = (target, type, x, y, opts = {}) =>
    target.dispatchEvent(new PointerEvent(type, {
      bubbles: true, cancelable: true, composed: true, pointerId: 1,
      pointerType: 'mouse', isPrimary: true, button: 0, buttons: 1,
      clientX: x, clientY: y, ...opts
    }));
  const blockOf = (title) => {
    const block = [...document.querySelectorAll('.cal-col .cal-ev[data-editable]')]
      .find((b) => b.textContent.includes(title));
    if (!block) throw new Error(`no editable "${title}" on screen`);
    block.scrollIntoView({ block: 'center' });
    return block;
  };
  """

  setup do
    TestMocks.stub_no_calendar_events()
    AvailabilityCache.clear_all()
    test_pid = self()

    Mox.stub(CalendarMock, :update_event, fn uid, _payload, _context ->
      send(test_pid, {:updated, uid})
      :ok
    end)

    :ok
  end

  # An organiser in UTC with a 24-hour clock and one writable Google calendar.
  defp organiser(session) do
    {session, user} =
      log_in_via_browser(session, %{dashboard_tour_seen_at: DateTime.utc_now(:second)})

    {:ok, profile} = Profiles.get_or_create_profile(user.id)
    {:ok, _profile} = Profiles.update_timezone(profile, "Etc/UTC")
    {:ok, _prefs} = CalendarPreferencesQueries.upsert(user.id, %{time_format: "24h"})

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

  defp timed(integration, title, %DateTime{} = start_at, minutes) do
    insert(:provider_calendar_event,
      calendar_integration: integration,
      provider: "google",
      provider_calendar_id: "work",
      summary: title,
      start_at: start_at,
      end_at: DateTime.add(start_at, minutes, :minute),
      all_day: false,
      sync_state: "synced"
    )
  end

  # The Tuesday of next week: two to eight days ahead.
  defp next_tuesday do
    base = Date.add(Date.utc_today(), 7)
    Date.add(base, 2 - Date.day_of_week(base))
  end

  defp open_calendar(session, {width, height}, query) do
    session
    |> resize_window(width, height)
    |> visit("/dashboard/calendar#{query}")
    |> wait_for_live()
    |> assert_has(css("#calendar-canvas[aria-busy='false']"))
  end

  defp read(session, script, args) do
    me = self()
    ref = make_ref()

    session =
      execute_script(session, script, args, fn result -> send(me, {:read, ref, result}) end)

    assert_receive {:read, ^ref, result}, 5_000
    {session, result}
  end

  defp block_height(session, title) do
    {session, height} =
      read(
        session,
        """
        const block = [...document.querySelectorAll('.cal-col .cal-ev')]
          .find((b) => b.textContent.includes(arguments[0]));
        return block ? block.getBoundingClientRect().height : null;
        """,
        [title]
      )

    assert is_number(height), "#{title} is not on screen"
    {session, height}
  end

  defp hour_drawn(px), do: css("#calendar-canvas .cal-grid[style*='--cal-hour:#{px}px']")

  feature "dragging an event's bottom edge resizes it, and the new end is saved", %{
    session: session
  } do
    {session, integration} = organiser(session)
    day = next_tuesday()
    iso = Date.to_iso8601(day)
    row = timed(integration, "Planning", DateTime.new!(day, ~T[10:00:00], "Etc/UTC"), 60)
    uid = row.uid

    session
    |> open_calendar({1280, 800}, "?view=week&date=#{iso}")
    |> assert_has(css(".cal-col[data-day='#{iso}'] .cal-ev .cal-ev-time", text: "10:00"))
    |> assert_has(hour_drawn(@hour_px))
    # Press on the end grip and pull it down one hour.
    |> execute_script(
      @pointer <>
        """
        const [title, hour] = arguments;
        const grip = blockOf(title).querySelector('[data-grip="end"]');
        if (!grip) throw new Error('no end grip');
        const r = grip.getBoundingClientRect();
        const x = r.left + r.width / 2;
        const y = r.bottom - 1;
        send(grip, 'pointerdown', x, y);
        send(grip, 'pointermove', x, y + 10);
        send(grip, 'pointermove', x, y + hour);
        send(grip, 'pointerup', x, y + hour, { buttons: 0 });
        """,
      ["Planning", @hour_px]
    )
    |> assert_has(css("#calendar-toast", text: "Now ends at 12:00"))
    |> assert_has(css(".cal-col[data-day='#{iso}'] .cal-ev", text: "12:00"))

    assert_receive {:updated, ^uid}, 5_000

    eventually(
      fn ->
        saved = Repo.reload!(row)

        assert {DateTime.truncate(saved.start_at, :second),
                DateTime.truncate(saved.end_at, :second)} ==
                 {DateTime.new!(day, ~T[10:00:00], "Etc/UTC"),
                  DateTime.new!(day, ~T[12:00:00], "Etc/UTC")}
      end,
      timeout: 5_000
    )
  end

  feature "Ctrl and the wheel zoom the hours in and out; the wheel alone does not", %{
    session: session
  } do
    {session, integration} = organiser(session)
    day = next_tuesday()
    iso = Date.to_iso8601(day)
    timed(integration, "Standup", DateTime.new!(day, ~T[10:00:00], "Etc/UTC"), 60)

    wheel = """
    const [deltaY, ctrlKey] = arguments;
    const scroller = document.querySelector('#calendar-canvas [data-scroll]');
    const r = scroller.getBoundingClientRect();
    scroller.dispatchEvent(new WheelEvent('wheel', {
      bubbles: true, cancelable: true, deltaY, deltaMode: 0, ctrlKey,
      clientX: r.left + r.width / 2, clientY: r.top + r.height / 2
    }));
    """

    session =
      session
      |> open_calendar({1280, 800}, "?view=week&date=#{iso}")
      |> assert_has(css(".cal-col[data-day='#{iso}'] .cal-ev", text: "Standup"))
      |> assert_has(hour_drawn(@hour_px))
      |> execute_script(wheel, [-200, false])
      |> assert_has(hour_drawn(@hour_px))

    {session, before} = block_height(session, "Standup")

    # 52 * e^(200 * 0.002) is 77.6, drawn as 78 (assets/js/calendar/zoom.js).
    session =
      session
      |> execute_script(wheel, [-200, true])
      |> assert_has(hour_drawn(78))

    {session, zoomed} = block_height(session, "Standup")

    assert zoomed - before > 20,
           "a one-hour event should grow with the hours: #{before}px to #{zoomed}px"

    session
    |> execute_script(wheel, [200, true])
    |> assert_has(hour_drawn(@hour_px))
  end

  feature "on a phone, a sideways swipe steps to the next day and back", %{session: session} do
    {session, _integration} = organiser(session)
    day = next_tuesday()
    iso = Date.to_iso8601(day)
    next = Date.to_iso8601(Date.add(day, 1))

    swipe = """
    const dx = arguments[0];
    const column = document.querySelector('#calendar-canvas .cal-col');
    const r = column.getBoundingClientRect();
    const scroller = document.querySelector('#calendar-canvas [data-scroll]').getBoundingClientRect();
    const x = window.innerWidth / 2;
    const y = Math.round((Math.max(r.top, scroller.top) + scroller.bottom) / 2);
    const send = (type, px, buttons) =>
      column.dispatchEvent(new PointerEvent(type, {
        bubbles: true, cancelable: true, composed: true, pointerId: 7,
        pointerType: 'touch', isPrimary: true, button: 0, buttons, clientX: px, clientY: y
      }));
    send('pointerdown', x, 1);
    send('pointermove', x + dx / 4, 1);
    send('pointermove', x + dx / 2, 1);
    send('pointermove', x + dx, 1);
    send('pointerup', x + dx, 0);
    """

    session =
      session
      |> open_calendar({390, 844}, "?view=day&date=#{iso}")
      |> assert_has(css("#calendar-tab-day[aria-current='page']"))
      |> assert_has(css("#calendar-canvas .cal-col[data-day='#{iso}']"))
      # A swipe to the left asks for the next day.
      |> execute_script(swipe, [-120])
      |> assert_has(css("#calendar-canvas .cal-col[data-day='#{next}']"))
      |> assert_has(css("#calendar-canvas .cal-col[data-day='#{iso}']", count: 0))

    eventually(fn -> assert current_url(session) =~ "date=#{next}" end, timeout: 5_000)

    # And one to the right, the previous.
    session =
      session
      |> execute_script(swipe, [120])
      |> assert_has(css("#calendar-canvas .cal-col[data-day='#{iso}']"))

    eventually(fn -> assert current_url(session) =~ "date=#{iso}" end, timeout: 5_000)
  end

  feature "on a phone, a long-press picks an event up and a drag moves it", %{session: session} do
    {session, integration} = organiser(session)
    day = next_tuesday()
    iso = Date.to_iso8601(day)
    row = timed(integration, "Coffee", DateTime.new!(day, ~T[10:00:00], "Etc/UTC"), 60)
    uid = row.uid

    touch = """
    const canvas = document.getElementById('calendar-canvas');
    canvas.setPointerCapture = () => {};
    canvas.releasePointerCapture = () => {};
    const touch = (target, type, x, y, buttons) =>
      target.dispatchEvent(new PointerEvent(type, {
        bubbles: true, cancelable: true, composed: true, pointerId: 9,
        pointerType: 'touch', isPrimary: true, button: 0, buttons, clientX: x, clientY: y
      }));
    """

    session
    |> open_calendar({390, 844}, "?view=day&date=#{iso}")
    |> assert_has(css(".cal-col[data-day='#{iso}'] .cal-ev[data-editable]", text: "Coffee"))
    # The finger rests on the block: after the long-press it is picked up.
    |> execute_script(
      touch <>
        """
        const block = [...document.querySelectorAll('.cal-col .cal-ev[data-editable]')]
          .find((b) => b.textContent.includes('Coffee'));
        // A scroll cancels a press, so the finger lands after the scroll has settled.
        block.scrollIntoView({ block: 'center' });
        requestAnimationFrame(() => requestAnimationFrame(() => {
          const r = block.getBoundingClientRect();
          window.__press = { x: r.left + r.width / 2, y: r.top + r.height / 2 };
          touch(block, 'pointerdown', window.__press.x, window.__press.y, 1);
        }));
        """,
      []
    )
    |> assert_has(css(".cal-ev.is-dragging", text: "Coffee"))
    # Then it travels one hour down and is let go.
    |> execute_script(
      touch <>
        """
        const hour = arguments[0];
        const { x, y } = window.__press;
        touch(canvas, 'pointermove', x, y + hour / 2, 1);
        touch(canvas, 'pointermove', x, y + hour, 1);
        touch(canvas, 'pointerup', x, y + hour, 0);
        """,
      [@hour_px]
    )
    |> assert_has(css("#calendar-toast", text: "Moved to"))
    |> assert_has(css("#calendar-toast", text: "11:00"))

    assert_receive {:updated, ^uid}, 5_000

    eventually(
      fn ->
        saved = Repo.reload!(row)

        assert {DateTime.truncate(saved.start_at, :second),
                DateTime.truncate(saved.end_at, :second)} ==
                 {DateTime.new!(day, ~T[11:00:00], "Etc/UTC"),
                  DateTime.new!(day, ~T[12:00:00], "Etc/UTC")}
      end,
      timeout: 5_000
    )
  end

  feature "on a phone, two fingers spreading over the grid zoom the hours", %{session: session} do
    {session, _integration} = organiser(session)
    iso = Date.to_iso8601(next_tuesday())

    session
    |> open_calendar({390, 844}, "?view=day&date=#{iso}")
    |> assert_has(hour_drawn(@hour_px))
    # Two fingers 80px apart move to 160px apart: twice the hour height.
    |> execute_script(
      """
      const canvas = document.getElementById('calendar-canvas');
      canvas.setPointerCapture = () => {};
      canvas.releasePointerCapture = () => {};
      const column = document.querySelector('#calendar-canvas .cal-col');
      const scroller = document.querySelector('#calendar-canvas [data-scroll]').getBoundingClientRect();
      const x = window.innerWidth / 2;
      const mid = Math.round((Math.max(column.getBoundingClientRect().top, scroller.top) + scroller.bottom) / 2);
      const finger = (type, id, y, buttons) =>
        column.dispatchEvent(new PointerEvent(type, {
          bubbles: true, cancelable: true, composed: true, pointerId: id,
          pointerType: 'touch', isPrimary: id === 1, button: 0, buttons, clientX: x, clientY: y
        }));
      finger('pointerdown', 1, mid - 40, 1);
      finger('pointerdown', 2, mid + 40, 1);
      finger('pointermove', 1, mid - 60, 1);
      finger('pointermove', 2, mid + 60, 1);
      finger('pointermove', 1, mid - 80, 1);
      finger('pointermove', 2, mid + 80, 1);
      requestAnimationFrame(() => requestAnimationFrame(() => {
        finger('pointerup', 1, mid - 80, 0);
        finger('pointerup', 2, mid + 80, 0);
      }));
      """,
      []
    )
    |> assert_has(hour_drawn(@hour_px * 2))
  end
end
