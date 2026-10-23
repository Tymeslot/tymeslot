defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceFreeBusyTest do
  @moduledoc """
  The preview's Edit button and Busy/Free toggle on the calendar: Edit
  opens the side panel, the toggle writes the event's free/busy with a toast
  that says what it means for bookings and can be undone, and bookings and
  their calendar copies explain where their state is set instead.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Mox
  import Tymeslot.AvailabilityTestHelpers, only: [offered: 3, open_schedule_for: 1]
  import Tymeslot.Factory, only: [insert: 2]
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.Google.EventMapper, as: GoogleEventMapper
  alias Tymeslot.Integrations.Calendar.Google.EventNormaliser, as: GoogleEventNormaliser
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.SeriesRuleQueries
  alias Tymeslot.Profiles

  @task_timeout 5_000

  setup %{conn: conn} do
    context = owner(conn)
    test_pid = self()

    stub(Tymeslot.CalendarMock, :update_event, fn _uid, payload, _context ->
      send(test_pid, {:provider_update, self(), payload})
      :ok
    end)

    review = event(context.integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")

    Map.merge(context, %{lv: lv, review: review, id: "event-#{review.id}"})
  end

  defp open(lv, id),
    do: lv |> element("#calendar-canvas") |> render_hook("calendar:open", %{"id" => id})

  defp await_provider_update(lv) do
    assert_receive {:provider_update, task_pid, payload}, @task_timeout
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
    render(lv)
    render(lv)
    payload
  end

  test "Edit opens the side panel on the event", %{lv: lv, id: id} do
    open(lv, id)

    assert has_element?(
             lv,
             ~s|#calendar-preview-edit[phx-click="calendar:edit"][phx-value-id="#{id}"]|
           )

    lv |> element("#calendar-preview-edit") |> render_click()

    assert has_element?(lv, "#calendar-panel")
    refute has_element?(lv, "#calendar-preview")
  end

  test "Free writes the event as free, says what it means, and can be undone", %{
    lv: lv,
    integration: integration,
    review: review,
    id: id
  } do
    open(lv, id)
    assert has_element?(lv, ~s|#calendar-preview-busy[aria-pressed="true"]|)

    lv |> element("#calendar-preview-free") |> render_click()

    assert %{transparency: "transparent"} = await_provider_update(lv)
    assert has_element?(lv, "#calendar-toast", "Shown as free. Guests can book this time.")
    assert has_element?(lv, ~s|#calendar-preview-free[aria-pressed="true"]|)
    assert has_element?(lv, "#calendar-preview", "Guests can book this time")

    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, review.uid)
    assert row.transparency == "transparent"

    lv |> element("#calendar-undo") |> render_click()
    assert %{transparency: "opaque"} = await_provider_update(lv)

    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, review.uid)
    assert row.transparency == "opaque"
  end

  test "choosing the state the event already has writes nothing", %{lv: lv, id: id} do
    open(lv, id)
    lv |> element("#calendar-preview-busy") |> render_click()

    refute_receive {:provider_update, _pid, _payload}, 100
    refute has_element?(lv, "#calendar-toast")
  end

  test "a busy toggle back says guests can't book", %{conn: conn, integration: integration} do
    focus =
      event(integration, "work", "Focus", ~U[2026-10-15 09:00:00Z], 120,
        transparency: "transparent"
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "event-#{focus.id}")
    lv |> element("#calendar-preview-busy") |> render_click()

    await_provider_update(lv)
    assert has_element?(lv, "#calendar-toast", "Shown as busy. Guests can't book this time.")
  end

  test "the calendar copy of a booking explains where its state is set", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    copy = event(integration, "work", "Booked call", ~U[2026-10-15 13:00:00Z], 30)

    # Cancelled, with its calendar copy not yet removed. A booking the grid
    # draws replaces its copy; this one is not drawn, so its copy shows.
    insert(:meeting,
      organizer_user: user,
      status: "cancelled",
      calendar_integration_id: integration.id,
      calendar_uid: copy.uid
    )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "event-#{copy.id}")

    refute has_element?(lv, "#calendar-preview-free")
    assert has_element?(lv, "#calendar-preview", "Set in the meeting type")
  end

  test "a forged toggle on a booking copy is refused", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    copy = event(integration, "work", "Booked call", ~U[2026-10-15 13:00:00Z], 30)

    # Cancelled, with its calendar copy not yet removed. A booking the grid
    # draws replaces its copy; this one is not drawn, so its copy shows.
    insert(:meeting,
      organizer_user: user,
      status: "cancelled",
      calendar_integration_id: integration.id,
      calendar_uid: copy.uid
    )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:set_free", %{"id" => "event-#{copy.id}", "free" => "true"})

    refute_receive {:provider_update, _pid, _payload}, 100
  end

  test "a booking offers neither Edit nor the toggle", %{conn: conn, user: user} do
    meeting =
      insert(:meeting,
        organizer_user: user,
        title: "Intro call",
        start_time: ~U[2026-10-15 10:00:00Z],
        end_time: ~U[2026-10-15 10:30:00Z],
        status: "confirmed"
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "booking-#{meeting.id}")

    refute has_element?(lv, "#calendar-preview-edit")
    refute has_element?(lv, "#calendar-preview-free")
    assert has_element?(lv, "#calendar-preview", "Set in the meeting type")
  end

  test "a refused toggle is flashed when no panel is open, and writes nothing", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    copy = event(integration, "work", "Booked call", ~U[2026-10-15 13:00:00Z], 30)

    # Cancelled, with its calendar copy not yet removed. A booking the grid
    # draws replaces its copy; this one is not drawn, so its copy shows.
    insert(:meeting,
      organizer_user: user,
      status: "cancelled",
      calendar_integration_id: integration.id,
      calendar_uid: copy.uid
    )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:set_free", %{"id" => "event-#{copy.id}", "free" => "true"})

    assert render(lv) =~ "Busy or free is set in the meeting type"
    refute has_element?(lv, "#calendar-toast")
    refute_receive {:provider_update, _pid, _payload}, 100
  end

  test "the toast does not promise bookings on a calendar that does not block them", %{
    conn: conn,
    user: user
  } do
    holidays =
      insert(:calendar_integration,
        user: user,
        name: "Holidays",
        provider: "google",
        is_active: true,
        calendar_list: [
          %{
            "id" => "hol",
            "name" => "Holidays",
            "selected" => true,
            "blocks_availability" => false
          }
        ]
      )

    holiday =
      event(holidays, "hol", "Bank holiday", ~U[2026-10-15 09:00:00Z], 60,
        transparency: "transparent"
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "event-#{holiday.id}")
    lv |> element("#calendar-preview-busy") |> render_click()

    await_provider_update(lv)
    assert has_element?(lv, "#calendar-toast", "Shown as busy.")
    refute has_element?(lv, "#calendar-toast", "Guests can't book")
    assert has_element?(lv, "#calendar-preview", "This calendar doesn't block bookings")
  end

  test "a repeating event asks its series question, and this event alone is written with Undo", %{
    conn: conn,
    integration: integration
  } do
    standup =
      event(integration, "work", "Standup", ~U[2026-10-14 08:30:00Z], 15,
        uid: "standup-series_20261014T083000Z",
        provider_event_id: "standup-series_20261014T083000Z",
        recurring_event_id: "standup-series"
      )

    {:ok, _row} =
      SeriesRuleQueries.put(integration.id, "standup-series", %{
        rule: "FREQ=DAILY",
        master_start: ~U[2026-10-01 08:30:00Z],
        fetched_at: DateTime.utc_now()
      })

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "event-#{standup.id}")
    lv |> element("#calendar-preview-free") |> render_click()

    assert has_element?(lv, "#calendar-series-scope", "Standup")
    refute_receive {:provider_update, _pid, _payload}, 100

    lv |> element("#calendar-scope-this_only") |> render_click()

    await_provider_update(lv)
    assert has_element?(lv, "#calendar-toast", "Shown as free. Guests can book this time.")
    assert has_element?(lv, "#calendar-undo")
  end

  # A Google calendar that keeps what the toggle writes to it: the update is
  # formatted as the Google adapter sends it, and the booking page reads the
  # event back through the Google normaliser.
  defp google_keeps_writes(integration, event) do
    test_pid = self()
    {:ok, stored} = Agent.start_link(fn -> %{"transparency" => "opaque"} end)

    stub(Tymeslot.CalendarMock, :update_event, fn _uid, payload, _context ->
      body = GoogleEventMapper.format_event_data(payload)
      Agent.update(stored, fn _previous -> body end)
      send(test_pid, {:provider_update, self(), payload})
      :ok
    end)

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
      body = Agent.get(stored, & &1)

      raw = %{
        "id" => event.uid,
        "status" => "confirmed",
        "summary" => event.summary,
        "transparency" => body["transparency"],
        "start" => %{"dateTime" => DateTime.to_iso8601(event.start_at)},
        "end" => %{"dateTime" => DateTime.to_iso8601(event.end_at)}
      }

      GoogleEventNormaliser.normalise_events([raw], %{
        calendar_integration_id: integration.id,
        provider_calendar_id: event.provider_calendar_id,
        synced_at: DateTime.utc_now()
      })
    end)
  end

  test "Free gives the time to the booking page, and Busy takes it back", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    {:ok, profile} = Profiles.get_profile_by_user_id(user.id)
    open_schedule_for(profile)

    # 10:00 UTC is 11:00 in London, two days after the frozen clock.
    standup = event(integration, "work", "Stand-up", ~U[2026-10-16 10:00:00Z], 30)
    google_keeps_writes(integration, standup)

    refute "11:00 AM" in offered(profile, ~D[2026-10-16], "30min")

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "event-#{standup.id}")
    lv |> element("#calendar-preview-free") |> render_click()

    assert %{transparency: "transparent"} = await_provider_update(lv)
    assert "11:00 AM" in offered(profile, ~D[2026-10-16], "30min")

    lv |> element("#calendar-preview-busy") |> render_click()

    assert %{transparency: "opaque"} = await_provider_update(lv)
    refute "11:00 AM" in offered(profile, ~D[2026-10-16], "30min")
  end

  test "the keys hint names E", %{lv: lv} do
    assert has_element?(lv, "#calendar-keys-hint", "E to edit it")
  end
end
