defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceMoveTest do
  @moduledoc """
  Moving and resizing on the new calendar: the change shows at once, is
  written to the calendar, says what happened, and can be undone; a change
  the calendar would refuse snaps back.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Phoenix.LiveView, only: [send_update: 3]
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.CalendarGrid.WriteGuardian
  alias Tymeslot.CalendarGrid.WriteQueue
  alias Ecto.Changeset
  alias Tymeslot.CalendarMock
  alias Tymeslot.Repo
  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface

  setup %{conn: conn} do
    context = owner(conn)
    test_pid = self()

    Mox.stub(CalendarMock, :update_event, fn uid, payload, _context ->
      send(test_pid, {:written, uid, payload})
      :ok
    end)

    review = event(context.integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")

    Map.merge(context, %{lv: lv, review: review, id: "event-#{review.id}"})
  end

  defp move(lv, id, start, finish),
    do:
      lv
      |> element("#calendar-canvas")
      |> render_hook("calendar:move", %{"id" => id, "start" => start, "end" => finish})

  defp pushed(lv, id) do
    assert_push_event(lv, "calendar:events", %{events: events})
    Enum.find(events, &(&1.id == id))
  end

  defp same?(a, b), do: DateTime.compare(a, b) == :eq

  defp hold_writes do
    test_pid = self()

    Mox.stub(CalendarMock, :update_event, fn uid, payload, _context ->
      send(test_pid, {:write_started, self(), uid, payload})

      receive do
        {:answer, answer} -> answer
      end
    end)
  end

  defp flush_pushes(lv) do
    receive do
      {_ref, {:push_event, _event, _payload}} -> flush_pushes(lv)
    after
      50 -> :ok
    end
  end

  test "a move shows at once, is written, and says where the event went", %{
    lv: lv,
    review: review,
    id: id
  } do
    move(lv, id, "2026-10-15T11:00", "2026-10-15T12:00")

    assert %{start: "2026-10-15T11:00", end: "2026-10-15T12:00"} = pushed(lv, id)
    assert has_element?(lv, "#calendar-toast", "Moved to Thu 15 Oct, 11:00")
    assert has_element?(lv, "#calendar-undo")

    uid = review.uid
    assert_receive {:written, ^uid, payload}
    assert same?(payload.start_time, ~U[2026-10-15 10:00:00Z])
    assert same?(payload.end_time, ~U[2026-10-15 11:00:00Z])
  end

  test "a resize says when the event now ends", %{lv: lv, id: id} do
    move(lv, id, "2026-10-14T10:00", "2026-10-14T11:30")

    assert has_element?(lv, "#calendar-toast", "Now ends at 11:30")
  end

  test "undo writes the event back where it was", %{lv: lv, review: review, id: id} do
    move(lv, id, "2026-10-15T11:00", "2026-10-15T12:00")
    assert_receive {:written, _uid, _moved}
    render(lv)

    lv |> element("#calendar-undo") |> render_click()

    # The undo waits behind the move's write if that has not answered yet.
    uid = review.uid
    assert_receive {:written, ^uid, payload}, 1_000
    assert same?(payload.start_time, ~U[2026-10-14 09:00:00Z])
    assert has_element?(lv, "#calendar-toast", "Moved back to Wed 14 Oct, 10:00")
  end

  test "Ctrl Z with nothing to undo says so", %{lv: lv} do
    lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})

    assert has_element?(lv, "#calendar-toast", "Nothing to undo.")
    refute has_element?(lv, "#calendar-undo")
  end

  test "an event on a read-only calendar snaps back and says why", %{
    conn: conn,
    integration: integration
  } do
    integration
    |> Changeset.change(
      calendar_list: [
        %{"id" => "work", "name" => "Work", "selected" => true},
        %{"id" => "shared", "name" => "Shared", "selected" => true, "read_only" => true}
      ]
    )
    |> Repo.update!()

    shared = event(integration, "shared", "Team offsite", ~U[2026-10-16 09:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    id = "event-#{shared.id}"

    move(lv, id, "2026-10-16T12:00", "2026-10-16T13:00")

    assert %{start: "2026-10-16T10:00"} = pushed(lv, id)
    assert render(lv) =~ "This calendar is read-only"
    refute_received {:written, _uid, _payload}
  end

  test "a guest's event moves without telling them, and says so", %{
    conn: conn,
    integration: integration
  } do
    call =
      event(integration, "work", "Intro call", ~U[2026-10-15 13:00:00Z], 30,
        attendees: [%{"email" => "ada@example.com"}]
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    move(lv, "event-#{call.id}", "2026-10-15T15:00", "2026-10-15T15:30")

    assert has_element?(lv, "#calendar-toast", "Guests haven't been told.")
  end

  describe "when the write fails" do
    test "the original is pushed back and the toast gives way to the failure", %{
      lv: lv,
      id: id
    } do
      Mox.stub(CalendarMock, :update_event, fn _uid, _payload, _context ->
        {:error, :provider_down}
      end)

      move(lv, id, "2026-10-15T11:00", "2026-10-15T12:00")

      assert_push_event(
        lv,
        "calendar:events",
        %{events: [%{id: ^id, start: "2026-10-14T10:00"}]},
        2_000
      )

      html = render(lv)
      refute html =~ ~s(id="calendar-toast")
      refute html =~ ~s(id="calendar-undo")
    end

    test "the change is no longer on the undo stack", %{lv: lv, id: id} do
      Mox.stub(CalendarMock, :update_event, fn _uid, _payload, _context ->
        {:error, :provider_down}
      end)

      move(lv, id, "2026-10-15T11:00", "2026-10-15T12:00")
      assert_push_event(lv, "calendar:events", %{events: [%{start: "2026-10-14T10:00"}]}, 2_000)
      render(lv)

      lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})

      assert has_element?(lv, "#calendar-toast", "Nothing to undo.")
    end
  end

  describe "a surface revived while a write is running" do
    test "keeps the one write the queue holds and waits behind it", %{
      lv: lv,
      review: review,
      id: id
    } do
      hold_writes()
      move(lv, id, "2026-10-15T11:00", "2026-10-15T12:00")
      assert_receive {:write_started, writer, _uid, _payload}

      # The organiser left and came back before the browser confirmed the
      # surface's removal: its guardian's queue is adopted, not driven again.
      send_update(lv.pid, CalendarSurface, id: "calendar", calendar_left: 1)
      render(lv)
      refute_receive {:write_started, _other, _uid, _payload}, 150

      # A change made now waits behind the write still running.
      move(lv, id, "2026-10-16T11:00", "2026-10-16T12:00")
      refute_receive {:write_started, _other, _uid, _payload}, 150

      send(writer, {:answer, :ok})
      uid = review.uid
      assert_receive {:write_started, second, ^uid, payload}, 1_000
      assert same?(payload.start_time, ~U[2026-10-16 10:00:00Z])
      send(second, {:answer, :ok})
      refute_receive {:write_started, _third, _uid, _payload}, 150
    end
  end

  describe "changes dropped behind another LiveView's write" do
    test "the organiser is told", %{lv: lv, user: user, review: review, id: id} do
      # Another LiveView of the organiser is writing the event.
      {queue, _effects} = WriteQueue.update(WriteQueue.new(), review, %{}, [], nil)
      :ok = WriteGuardian.mirror(queue, user.id)
      [{lender, _value}] = Registry.lookup(WriteGuardian.registry(), self())

      send_update(lv.pid, CalendarSurface, id: "calendar", calendar_left: 1)
      render(lv)
      flush_pushes(lv)

      # The move waits behind it; the series then changes under it.
      move(lv, id, "2026-10-15T11:00", "2026-10-15T12:00")

      send_update(lv.pid, CalendarSurface,
        id: "calendar",
        action: :event_writes_released,
        release: {lender, WriteQueue.key(review), :series_changed}
      )

      render(lv)
      render(lv)
      assert render(lv) =~ "a change you made while it was saving was not applied"
      refute_received {:written, _uid, _payload}
    end
  end
end
