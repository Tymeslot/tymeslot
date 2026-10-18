defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceTransferTest do
  @moduledoc """
  Moving an event to another calendar from the side panel: a single event
  moves at once with a toast and Undo, a repeating one asks first and moves
  its whole series, and the calendar copy of a booking stays where it is.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Ecto.Query, only: [from: 2]
  import Mox
  import Phoenix.LiveView, only: [send_update: 3]
  import Tymeslot.Factory, only: [insert: 2]
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo
  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface

  # Provider writes run in a supervised task; allow for a busy test machine.
  @task_timeout 5_000

  setup :verify_on_exit!

  setup %{conn: conn} do
    context = owner(conn)
    test_pid = self()

    stub(Tymeslot.CalendarMock, :create_event, fn payload, _context ->
      send(test_pid, {:provider_call, self(), {:create, payload}})
      {:ok, CreatedEvent.new(payload.uid)}
    end)

    stub(Tymeslot.CalendarMock, :delete_event, fn uid, _context, _opts ->
      send(test_pid, {:provider_call, self(), {:delete, uid}})
      :ok
    end)

    review = event(context.integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")

    Map.merge(context, %{lv: lv, review: review, id: "event-#{review.id}"})
  end

  defp open_panel(lv, id),
    do: lv |> element("#calendar-canvas") |> render_hook("calendar:edit", %{"id" => id})

  defp choose_calendar(lv, key),
    do: lv |> form("#calendar-panel-calendar-form") |> render_change(%{"calendar" => key})

  # Collects `count` provider calls, waits for the task that made them to
  # exit, then renders twice: once for the LiveView to take the result, once
  # for the surface to apply what it was sent.
  defp await_move(lv, count) do
    calls =
      for _call <- 1..count do
        assert_receive {:provider_call, task_pid, call}, @task_timeout
        {task_pid, call}
      end

    {task_pid, _call} = hd(calls)
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
    render(lv)
    render(lv)
    Enum.map(calls, fn {_pid, call} -> call end)
  end

  defp rows(integration_id, summary) do
    Repo.all(
      from(e in ProviderCalendarEventSchema,
        where: e.calendar_integration_id == ^integration_id and e.summary == ^summary,
        select: e.provider_calendar_id
      )
    )
  end

  test "the select offers the writable calendars, grouped by account, with the event's chosen", %{
    lv: lv,
    integration: integration,
    id: id
  } do
    open_panel(lv, id)

    assert has_element?(lv, ~s|#calendar-panel-calendar optgroup[label="Work account"]|)

    assert has_element?(
             lv,
             ~s|#calendar-panel-calendar option[value="#{integration.id}:work"][selected]|
           )

    assert has_element?(lv, ~s|#calendar-panel-calendar option[value="#{integration.id}:family"]|)
  end

  test "a single event moves at once, says where it went, and can be moved back", %{
    lv: lv,
    integration: integration,
    review: review,
    id: id
  } do
    open_panel(lv, id)
    choose_calendar(lv, "#{integration.id}:family")

    assert [{:create, _payload}, {:delete, uid}] = await_move(lv, 2)
    assert uid == review.uid
    assert rows(integration.id, "Design review") == ["family"]
    assert has_element?(lv, "#calendar-toast", "Moved to Family")
    assert has_element?(lv, "#calendar-panel", "Saved")

    lv |> element("#calendar-undo") |> render_click()

    assert [{:create, _payload}, {:delete, _uid}] = await_move(lv, 2)
    assert rows(integration.id, "Design review") == ["work"]
    assert has_element?(lv, "#calendar-toast", "Moved back to Work")
  end

  test "the panel follows the event to its new identity", %{
    lv: lv,
    integration: integration,
    review: review,
    id: id
  } do
    open_panel(lv, id)
    choose_calendar(lv, "#{integration.id}:family")
    await_move(lv, 2)

    # The original row is gone; a panel still pointing at it would be empty.
    refute Repo.get(ProviderCalendarEventSchema, review.id)

    assert has_element?(
             lv,
             ~s|#calendar-panel-calendar option[value="#{integration.id}:family"][selected]|
           )
  end

  test "a move whose original stayed behind says so and offers no undo", %{
    lv: lv,
    integration: integration,
    id: id
  } do
    test_pid = self()

    stub(Tymeslot.CalendarMock, :delete_event, fn uid, _context, _opts ->
      send(test_pid, {:provider_call, self(), {:delete, uid}})
      {:error, :forbidden}
    end)

    open_panel(lv, id)
    choose_calendar(lv, "#{integration.id}:family")
    await_move(lv, 2)

    assert has_element?(lv, "#calendar-toast", "the original could not be removed")
    refute has_element?(lv, "#calendar-undo")
  end

  test "a failed move puts the event back on its calendar", %{
    lv: lv,
    integration: integration,
    id: id
  } do
    test_pid = self()

    stub(Tymeslot.CalendarMock, :create_event, fn payload, _context ->
      send(test_pid, {:provider_call, self(), {:create, payload}})
      {:error, :forbidden}
    end)

    open_panel(lv, id)
    choose_calendar(lv, "#{integration.id}:family")
    await_move(lv, 1)

    assert rows(integration.id, "Design review") == ["work"]
    assert render(lv) =~ "Could not move the event. It is still on its original calendar."

    assert has_element?(
             lv,
             ~s|#calendar-panel-calendar option[value="#{integration.id}:work"][selected]|
           )
  end

  test "a calendar the panel never offered is ignored", %{lv: lv, id: id} do
    expect(Tymeslot.CalendarMock, :create_event, 0, fn _payload, _context -> :ok end)

    open_panel(lv, id)
    choose_calendar(lv, "999999:elsewhere")

    refute_receive {:provider_call, _pid, _call}, 100
  end

  test "the calendar copy of a booking stays where it is", %{
    conn: conn,
    integration: integration
  } do
    copy = event(integration, "work", "Booked call", ~U[2026-10-15 13:00:00Z], 30)
    insert(:meeting, calendar_integration_id: integration.id, calendar_uid: copy.uid)
    expect(Tymeslot.CalendarMock, :create_event, 0, fn _payload, _context -> :ok end)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_panel(lv, "event-#{copy.id}")
    choose_calendar(lv, "#{integration.id}:family")

    assert render(lv) =~ "This is a booking. Reschedule or cancel it from Bookings."
    refute_receive {:provider_call, _pid, _call}, 100
  end

  describe "a repeating event" do
    setup %{conn: conn, integration: integration} do
      standup =
        event(integration, "work", "Standup", ~U[2026-10-14 08:30:00Z], 15,
          recurring_event_id: "standup-series",
          uid: "standup-series_20261014T083000Z",
          provider_event_id: "standup-series_20261014T083000Z"
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_panel(lv, "event-#{standup.id}")

      %{lv: lv, standup: standup}
    end

    test "asks before moving the whole series", %{lv: lv, integration: integration} do
      expect(Tymeslot.CalendarMock, :create_event, 0, fn _payload, _context -> :ok end)

      choose_calendar(lv, "#{integration.id}:family")

      assert has_element?(
               lv,
               "#calendar-series-move",
               "Move every event in this series to Family?"
             )
    end

    test "cancelling leaves the series where it was", %{lv: lv, integration: integration} do
      choose_calendar(lv, "#{integration.id}:family")
      lv |> element("#calendar-series-move-cancel") |> render_click()

      refute has_element?(lv, "#calendar-series-move")

      assert has_element?(
               lv,
               ~s|#calendar-panel-calendar option[value="#{integration.id}:work"][selected]|
             )
    end

    test "once moved, the panel closes and the toast offers no undo", %{
      lv: lv,
      standup: standup
    } do
      send_update(lv.pid, CalendarSurface,
        id: "calendar",
        action: :series_moved,
        moved_event: standup
      )

      render(lv)

      refute has_element?(lv, "#calendar-panel")
      refute has_element?(lv, "#calendar-undo")
    end
  end
end
