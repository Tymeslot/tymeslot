defmodule TymeslotWeb.E2E.CalendarJourneysTest do
  @moduledoc """
  The calendar's core journeys in a real browser at 1280x800: a drag
  over an empty slot opens quick create and Save adds the event; a drag of
  an event to the next day moves it and the toast's Undo puts it back; the
  side panel renames an event; a click on an all-day bar opens its preview;
  quick create opens a closed Saturday for booking and Undo closes it
  again; a booking request opens to Accept, which confirms it; the side
  panel makes a Tymeslot meeting with a guest.

  Only a browser runs the hook's pointer handling, the toast's Undo button
  and the preview's buttons together. Drags are synthetic pointer events
  (pointerType "mouse"), dispatched where a mouse would press; the canvas's
  pointer capture is replaced with a no-op for them, since a synthetic
  pointer cannot be captured. Calendar writes are stubbed at the provider
  boundary (`Tymeslot.CalendarMock`).
  """

  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag :calendar

  import Tymeslot.TestHelpers.Eventually

  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  require Ecto.Query, as: Query

  @pointer """
  const canvas = document.getElementById('calendar-canvas');
  canvas.setPointerCapture = () => {};
  canvas.releasePointerCapture = () => {};
  const send = (target, type, x, y, buttons) =>
    target.dispatchEvent(new PointerEvent(type, {
      bubbles: true, cancelable: true, composed: true, pointerId: 1,
      pointerType: 'mouse', isPrimary: true, button: 0, buttons, clientX: x, clientY: y
    }));
  """

  setup do
    TestMocks.stub_no_calendar_events()
    AvailabilityCache.clear_all()
    test_pid = self()

    Mox.stub(CalendarMock, :create_event, fn event_data, _context ->
      send(test_pid, {:created, event_data})
      {:ok, CreatedEvent.new(event_data.uid, provider_event_id: "g-" <> event_data.uid)}
    end)

    Mox.stub(CalendarMock, :update_event, fn uid, _payload, _context ->
      send(test_pid, {:updated, uid})
      :ok
    end)

    :ok
  end

  # An organiser in UTC (so a date is the same day on the server, in the
  # browser and in the test), tour already seen, with one writable Google
  # calendar. Profile creation gave them a Monday to Friday schedule and the
  # default meeting types.
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

    {session, user, integration}
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

  # The given ISO weekday (1 Monday … 7 Sunday) in the week a week from now:
  # always ahead, and a Tuesday and its Wednesday share a week whichever day
  # the week starts on.
  defp ahead(iso_weekday) do
    base = Date.add(Date.utc_today(), 7)
    Date.add(base, iso_weekday - Date.day_of_week(base))
  end

  defp open_calendar(session, query) do
    session
    |> resize_window(1280, 800)
    |> visit("/dashboard/calendar#{query}")
    |> wait_for_live()
    |> assert_has(css("#calendar-canvas[aria-busy='false']"))
  end

  # Presses on the empty middle of the day's column, a third of the way down
  # the visible grid, and drags 80px down.
  defp drag_to_create(session, iso) do
    execute_script(
      session,
      @pointer <>
        """
        const column = document.querySelector(`.cal-col[data-day="${arguments[0]}"]`);
        if (!column) throw new Error('no column for ' + arguments[0]);
        const scroller = canvas.querySelector('[data-scroll]').getBoundingClientRect();
        const top = canvas.querySelector('.cal-top')?.getBoundingClientRect().bottom ?? scroller.top;
        const rect = column.getBoundingClientRect();
        const x = rect.left + rect.width / 2;
        const y = Math.round(top + (scroller.bottom - top) / 3);
        send(column, 'pointerdown', x, y, 1);
        send(column, 'pointermove', x, y + 20, 1);
        send(column, 'pointermove', x, y + 80, 1);
        send(column, 'pointerup', x, y + 80, 0);
        """,
      [iso]
    )
  end

  # Presses on the middle of the event's block and drops it at the same
  # height in the other day's column.
  defp drag_event(session, title, from, to) do
    execute_script(
      session,
      @pointer <>
        """
        const [title, from, to] = arguments;
        const block = [...document.querySelectorAll(`.cal-col[data-day="${from}"] .cal-ev[data-editable]`)]
          .find((b) => b.textContent.includes(title));
        if (!block) throw new Error(`no movable "${title}" on ${from}`);
        block.scrollIntoView({ block: 'center' });
        const r = block.getBoundingClientRect();
        const target = document.querySelector(`.cal-col[data-day="${to}"]`).getBoundingClientRect();
        const y = r.top + r.height / 2;
        const x0 = r.left + r.width / 2;
        const x1 = target.left + target.width / 2;
        send(block, 'pointerdown', x0, y, 1);
        send(block, 'pointermove', x0 + 10, y, 1);
        send(block, 'pointermove', x1, y, 1);
        send(block, 'pointerup', x1, y, 0);
        """,
      [title, from, to]
    )
  end

  feature "a drag over an empty slot opens quick create, and Save adds the event", %{
    session: session
  } do
    {session, _user, _integration} = organiser(session)
    iso = Date.to_iso8601(ahead(2))

    session
    |> open_calendar("?view=day&date=#{iso}")
    |> refute_has(css("#calendar-quick-create"))
    |> drag_to_create(iso)
    |> assert_has(css("#calendar-quick-create"))
    |> fill_in(css("#calendar-qc-field"), with: "Planning session")
    |> click(css("#calendar-quick-create [data-qc-save]"))
    |> assert_has(css("#calendar-toast", text: "Added"))
    |> assert_has(css(".cal-col[data-day='#{iso}'] .cal-ev", text: "Planning session"))

    assert_receive {:created, %{summary: "Planning session"}}, 5_000
  end

  feature "a drag to the next day moves the event, and Undo puts it back", %{session: session} do
    {session, _user, integration} = organiser(session)
    tuesday = ahead(2)
    wednesday = Date.add(tuesday, 1)
    tue = Date.to_iso8601(tuesday)
    wed = Date.to_iso8601(wednesday)

    row =
      timed(integration, "Roadmap review", DateTime.new!(tuesday, ~T[10:00:00], "Etc/UTC"), 60)

    uid = row.uid

    session =
      session
      |> open_calendar("?view=week&date=#{tue}")
      |> assert_has(css(".cal-col[data-day='#{tue}'] .cal-ev", text: "Roadmap review"))
      |> drag_event("Roadmap review", tue, wed)
      |> assert_has(css("#calendar-toast", text: "Moved to"))
      |> assert_has(css(".cal-col[data-day='#{wed}'] .cal-ev", text: "Roadmap review"))

    assert_receive {:updated, ^uid}, 5_000

    eventually(fn -> assert DateTime.to_date(Repo.reload!(row).start_at) == wednesday end,
      timeout: 5_000
    )

    session
    |> click(css("#calendar-undo"))
    |> assert_has(css("#calendar-toast", text: "Moved back to"))
    |> assert_has(css(".cal-col[data-day='#{tue}'] .cal-ev", text: "Roadmap review"))
    |> assert_has(css(".cal-col[data-day='#{wed}'] .cal-ev", text: "Roadmap review", count: 0))

    assert_receive {:updated, ^uid}, 5_000

    eventually(fn -> assert DateTime.to_date(Repo.reload!(row).start_at) == tuesday end,
      timeout: 5_000
    )
  end

  feature "the side panel renames an event", %{session: session} do
    {session, _user, integration} = organiser(session)
    day = ahead(2)
    iso = Date.to_iso8601(day)
    row = timed(integration, "Original title", DateTime.new!(day, ~T[11:00:00], "Etc/UTC"), 60)
    uid = row.uid

    session
    |> open_calendar("?view=day&date=#{iso}")
    |> click(css(".cal-col .cal-ev", text: "Original title"))
    |> assert_has(css("#calendar-preview", text: "Original title"))
    |> click(css("#calendar-preview-edit"))
    |> assert_has(css("#calendar-panel"))
    |> clear(css("#calendar-panel-title"))
    |> fill_in(css("#calendar-panel-title"), with: "Renamed in browser")
    |> send_keys([:enter])
    |> assert_has(css(".cal-col .cal-ev", text: "Renamed in browser"))

    assert_receive {:updated, ^uid}, 5_000
    eventually(fn -> assert Repo.reload!(row).summary == "Renamed in browser" end, timeout: 5_000)
  end

  feature "a click on an all-day bar opens its preview and no +N list", %{session: session} do
    {session, _user, integration} = organiser(session)
    day = ahead(3)
    next = Date.add(day, 1)

    insert(:provider_calendar_event,
      calendar_integration: integration,
      provider: "google",
      provider_calendar_id: "work",
      summary: "Company holiday",
      all_day: true,
      start_date: day,
      end_date: next,
      start_at: DateTime.new!(day, ~T[00:00:00], "Etc/UTC"),
      end_at: DateTime.new!(next, ~T[00:00:00], "Etc/UTC"),
      sync_state: "synced"
    )

    session
    |> open_calendar("?view=week&date=#{Date.to_iso8601(day)}")
    |> click(css(".cal-allday .cal-adbar", text: "Company holiday"))
    |> assert_has(css("#calendar-preview", text: "Company holiday"))
    |> refute_has(css(".cal-list"))
  end

  feature "quick create opens a closed Saturday for booking, and Undo closes it again", %{
    session: session
  } do
    {session, _user, _integration} = organiser(session)
    iso = Date.to_iso8601(ahead(6))

    session
    |> open_calendar("?view=day&date=#{iso}")
    |> refute_has(css(".cal-col[data-day='#{iso}'] .cal-bookable"))
    |> drag_to_create(iso)
    |> assert_has(css("#calendar-quick-create"))
    |> click(css("#calendar-quick-create [data-qc-kind='open']"))
    |> assert_has(css("#calendar-quick-create [data-qc-kind='open'][aria-pressed='true']"))
    |> click(css("#calendar-quick-create [data-qc-repeat='once']"))
    |> click(css("#calendar-quick-create [data-qc-save]"))
    |> assert_has(css("#calendar-toast", text: "Open for "))
    |> assert_has(css(".cal-col[data-day='#{iso}'] .cal-bookable", minimum: 1))
    |> click(css("#calendar-undo"))
    |> assert_has(css("#calendar-toast", text: "put back."))
    |> assert_has(css(".cal-col[data-day='#{iso}'] .cal-bookable", count: 0))
  end

  feature "a booking request opens to Accept, which confirms it", %{session: session} do
    {session, user, _integration} = organiser(session)

    consultation =
      insert(:meeting_type,
        user: user,
        name: "Consultation",
        slug: "consultation",
        duration_minutes: 30,
        requires_approval: true,
        is_active: true,
        sort_order: 0
      )

    tomorrow = Date.add(Date.utc_today(), 1)
    start = DateTime.new!(tomorrow, ~T[10:00:00], "Etc/UTC")

    held =
      insert(:meeting,
        organizer_user: user,
        organizer_user_id: user.id,
        organizer_email: user.email,
        meeting_type: "Consultation",
        meeting_type_id: consultation.id,
        duration: 30,
        status: "awaiting_approval",
        attendee_name: "Anna Kowalski",
        attendee_email: "anna@example.com",
        title: "Consultation with Anna Kowalski",
        summary: "Consultation with Anna Kowalski",
        start_time: start,
        end_time: DateTime.add(start, 30, :minute),
        approval_requested_at: DateTime.utc_now(:second),
        approval_deadline_at: DateTime.add(start, -1, :hour)
      )

    session
    |> open_calendar("?view=day&date=#{Date.to_iso8601(tomorrow)}")
    |> click(css(".cal-col .cal-ev", text: "Anna Kowalski"))
    |> assert_has(css("#calendar-preview-accept"))
    |> assert_has(css("#calendar-preview-decline"))
    |> click(css("#calendar-preview-accept"))
    |> assert_has(css("#app-flash-group", text: "Booking confirmed. The invitee has been told."))
    |> assert_has(css("#calendar-preview-cancel"))
    |> assert_has(css("#calendar-preview-accept", count: 0))

    eventually(fn -> assert Repo.get!(MeetingSchema, held.id).status == "confirmed" end,
      timeout: 5_000
    )
  end

  feature "the side panel makes a Tymeslot meeting with a guest", %{session: session} do
    {session, user, _integration} = organiser(session)
    iso = Date.to_iso8601(ahead(2))

    session
    |> open_calendar("?view=day&date=#{iso}")
    |> drag_to_create(iso)
    |> assert_has(css("#calendar-quick-create"))
    |> click(css("#calendar-quick-create [data-qc-more]"))
    |> assert_has(css("#calendar-panel-new-form"))
    |> fill_in(css("#calendar-panel-new-title"), with: "Kick-off")
    |> fill_in(css("[id^='calendar-panel-guest-email-']"), with: "guest@example.com")
    |> click(css("#calendar-panel-guest-add"))
    |> click(css("#calendar-panel-meeting-toggle"))
    |> fill_in(css("#calendar-panel-meeting-guest-name"), with: "Ada Lovelace")
    |> click(css("#calendar-panel-create"))
    |> assert_has(css("#app-flash-group", text: "Meeting created and invitation sent"))
    |> assert_has(css(".cal-col[data-day='#{iso}'] .cal-ev:not(.is-draft)", text: "Kick-off"))

    eventually(
      fn ->
        assert [%MeetingSchema{attendee_email: "guest@example.com"}] =
                 Repo.all(Query.where(MeetingSchema, organizer_user_id: ^user.id))
      end,
      timeout: 5_000
    )
  end
end
