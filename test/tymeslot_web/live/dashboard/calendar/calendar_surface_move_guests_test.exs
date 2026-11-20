defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceMoveGuestsTest do
  @moduledoc """
  A drag or resize never emails the event's guests, but the change stays
  untold until the organiser tells them: the side panel opened on the event
  afterwards offers "Tell guests" for it, and telling them settles it.
  """

  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.CalendarMock
  alias Tymeslot.Meetings.AttendeeNotifications.Worker
  alias Tymeslot.Workers.EmailWorker

  @task_timeout 5_000

  setup %{conn: conn} do
    context = owner(conn)
    test_pid = self()

    Mox.stub(CalendarMock, :update_event, fn _uid, payload, _context ->
      send(test_pid, {:written, self(), payload})
      :ok
    end)

    call =
      event(context.integration, "work", "Intro call", ~U[2026-10-15 13:00:00Z], 30,
        attendees: [%{"email" => "ada@example.com"}]
      )

    {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")
    Map.merge(context, %{lv: lv, call: call, id: "event-#{call.id}"})
  end

  defp move(lv, id, start, finish) do
    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:move", %{"id" => id, "start" => start, "end" => finish})

    await_write(lv)
  end

  # The write runs in a task; the surface hears its answer once it is done.
  defp await_write(lv) do
    assert_receive {:written, task_pid, _payload}, @task_timeout
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
    render(lv)
    render(lv)
  end

  defp open_panel(lv, id),
    do: lv |> element("#calendar-canvas") |> render_hook("calendar:edit", %{"id" => id})

  defp close_panel(lv), do: lv |> element("#calendar-panel-close") |> render_click()

  test "the panel opened after a drag offers to tell the guests, and the drag told nobody", %{
    lv: lv,
    id: id
  } do
    move(lv, id, "2026-10-15T15:00", "2026-10-15T15:30")
    assert all_enqueued(worker: Worker) == []
    assert all_enqueued(worker: EmailWorker) == []

    open_panel(lv, id)

    assert has_element?(
             lv,
             "#calendar-panel-untold",
             "Guests haven't been told about these changes"
           )
  end

  test "Tell guests after a drag sends one update and the change is no longer untold", %{
    lv: lv,
    call: call,
    id: id
  } do
    move(lv, id, "2026-10-15T15:00", "2026-10-15T15:30")
    open_panel(lv, id)

    lv |> element("#calendar-panel-tell-guests") |> render_click()

    assert_enqueued(
      worker: Worker,
      args: %{"event_id" => call.id, "kind" => "provider_calendar_event", "action" => "update"}
    )

    refute has_element?(lv, "#calendar-panel-untold")

    close_panel(lv)
    open_panel(lv, id)
    refute has_element?(lv, "#calendar-panel-untold")
  end

  test "two drags count from where the event was before the first", %{lv: lv, id: id} do
    move(lv, id, "2026-10-15T15:00", "2026-10-15T15:30")
    move(lv, id, "2026-10-15T16:00", "2026-10-15T16:30")
    open_panel(lv, id)

    assert has_element?(lv, "#calendar-panel-untold")
  end

  test "a drag undone leaves nothing untold", %{lv: lv, id: id} do
    move(lv, id, "2026-10-15T15:00", "2026-10-15T15:30")

    lv |> element("#calendar-undo") |> render_click()
    await_write(lv)

    open_panel(lv, id)
    refute has_element?(lv, "#calendar-panel-untold")
  end

  test "an event without guests never offers it after a drag", %{
    conn: conn,
    integration: integration
  } do
    solo = event(integration, "work", "Focus", ~U[2026-10-15 09:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    move(lv, "event-#{solo.id}", "2026-10-15T16:00", "2026-10-15T17:00")
    open_panel(lv, "event-#{solo.id}")

    refute has_element?(lv, "#calendar-panel-untold")
  end
end
