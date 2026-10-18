defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceFreeBusyTest do
  @moduledoc """
  The preview's Edit button and Busy/Free toggle on the new calendar: Edit
  opens the side panel, the toggle writes the event's free/busy with a toast
  that says what it means for bookings and can be undone, and bookings and
  their calendar copies explain where their state is set instead.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Mox
  import Tymeslot.Factory, only: [insert: 2]
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.SeriesRuleQueries

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

    await_provider_update(lv)
    assert has_element?(lv, "#calendar-toast", "Shown as free. Guests can book this time.")
    assert has_element?(lv, ~s|#calendar-preview-free[aria-pressed="true"]|)
    assert has_element?(lv, "#calendar-preview", "Guests can book this time")

    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, review.uid)
    assert row.transparency == "transparent"

    lv |> element("#calendar-undo") |> render_click()
    await_provider_update(lv)

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

    insert(:meeting,
      organizer_user: user,
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

    insert(:meeting,
      organizer_user: user,
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
    meeting =
      insert(:meeting,
        organizer_user: user,
        organizer_user_id: user.id,
        capacity: 2,
        start_time: ~U[2026-10-15 10:00:00Z],
        end_time: ~U[2026-10-15 11:00:00Z]
      )

    insert(:participant, meeting: meeting)

    workshop =
      event(integration, "work", "Group workshop", ~U[2026-10-15 10:00:00Z], 60,
        uid: meeting.calendar_uid
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "event-#{workshop.id}")
    lv |> element("#calendar-preview-free") |> render_click()

    assert render(lv) =~ "This is a group booking."
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

  test "the keys hint names E", %{lv: lv} do
    assert has_element?(lv, "#calendar-keys-hint", "E to edit it")
  end
end
