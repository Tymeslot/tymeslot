defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceSeriesTest do
  @moduledoc """
  Moving one event of a repeating series asks which events the change is
  for: this one (undoable), this and the following ones, or all of them;
  cancelling puts it back.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  setup %{conn: conn} do
    context = owner(conn)
    test_pid = self()

    Mox.stub(Tymeslot.CalendarMock, :update_event, fn uid, payload, _context ->
      send(test_pid, {:written, uid, payload})
      :ok
    end)

    standup =
      event(context.integration, "work", "Standup", ~U[2026-10-14 08:30:00Z], 15,
        recurring_event_id: "standup-series",
        uid: "standup-series_20261014T083000Z"
      )

    {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:move", %{
      "id" => "event-#{standup.id}",
      "start" => "2026-10-14T10:00",
      "end" => "2026-10-14T10:15"
    })

    %{lv: lv, standup: standup, id: "event-#{standup.id}"}
  end

  defp pushed_start(lv, id) do
    assert_push_event(lv, "calendar:events", %{events: events})
    events |> Enum.find(&(&1.id == id)) |> Map.fetch!(:start)
  end

  test "asks which events, showing the move meanwhile", %{lv: lv, id: id} do
    assert pushed_start(lv, id) == "2026-10-14T10:00"
    assert has_element?(lv, "#calendar-series-scope", "Standup")
    assert has_element?(lv, "#calendar-scope-this_only")
    assert has_element?(lv, "#calendar-scope-following")
    assert has_element?(lv, "#calendar-scope-all")
    assert has_element?(lv, "#calendar-scope-undo-note", "Only “This event” can be undone.")
    refute_received {:written, _uid, _payload}
  end

  test "this event only is written and can be undone", %{lv: lv, standup: standup} do
    lv |> element("#calendar-scope-this_only") |> render_click()

    uid = standup.uid
    assert_receive {:written, ^uid, _payload}
    refute has_element?(lv, "#calendar-series-scope")
    assert has_element?(lv, "#calendar-undo")
  end

  test "all events is written and says it cannot be undone here", %{lv: lv, standup: standup} do
    html = lv |> element("#calendar-scope-all") |> render_click()

    uid = standup.uid
    assert_receive {:written, ^uid, _payload}

    assert html =~ "Series changed. Changes to several events can&#39;t be undone here."
    refute html =~ ~s(id="calendar-undo")
  end

  test "a failed change to the whole series leaves an earlier move of the event undoable", %{
    lv: lv,
    standup: standup,
    id: id
  } do
    uid = standup.uid
    lv |> element("#calendar-scope-this_only") |> render_click()
    assert_receive {:written, ^uid, _moved}
    render(lv)

    Mox.stub(Tymeslot.CalendarMock, :update_event, fn _uid, _payload, _context ->
      {:error, :provider_down}
    end)

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:move", %{
      "id" => id,
      "start" => "2026-10-14T11:00",
      "end" => "2026-10-14T11:15"
    })

    lv |> element("#calendar-scope-all") |> render_click()

    # Earlier pushes (the first move, the this-only write) also show 10:00, so
    # skip past them to the optimistic 11:00 and wait for the failed write to
    # put 10:00 back; only then is it safe to swap the stub.
    await_start(lv, id, "2026-10-14T11:00")
    await_start(lv, id, "2026-10-14T10:00")
    render(lv)

    test_pid = self()

    Mox.stub(Tymeslot.CalendarMock, :update_event, fn uid, payload, _context ->
      send(test_pid, {:written, uid, payload})
      :ok
    end)

    lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})

    assert_receive {:written, ^uid, undone}, 1_000
    assert DateTime.compare(undone.start_time, ~U[2026-10-14 08:30:00Z]) == :eq
  end

  # Waits for the push that draws the event at `start` again.
  defp await_start(lv, id, start) do
    assert_push_event(lv, "calendar:events", %{events: events}, 1_000)

    unless match?(%{start: ^start}, Enum.find(events, &(&1.id == id))),
      do: await_start(lv, id, start)
  end

  test "this and following events is written with that scope", %{lv: lv} do
    lv |> element("#calendar-scope-following") |> render_click()

    assert_receive {:written, _uid, payload}
    assert %{occurrence: %{scope: :following}} = payload
    refute has_element?(lv, "#calendar-series-scope")
  end

  test "cancelling puts the event back", %{lv: lv, id: id} do
    assert pushed_start(lv, id) == "2026-10-14T10:00"

    lv |> element("#calendar-series-scope button", "Cancel") |> render_click()

    assert pushed_start(lv, id) == "2026-10-14T09:30"
    refute has_element?(lv, "#calendar-series-scope")
    refute_received {:written, _uid, _payload}
  end

  test "a scope the client invents is ignored and the question stays open", %{lv: lv} do
    for bad <- ["everything", "", 7, nil, %{"a" => 1}] do
      lv
      |> element("#calendar-canvas")
      |> render_hook("calendar:choose_scope", %{"scope" => bad})
    end

    assert has_element?(lv, "#calendar-series-scope")
    refute_received {:written, _uid, _payload}
  end
end
