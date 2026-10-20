defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceMoveTest do
  @moduledoc """
  Moving and resizing on the calendar: the change shows at once, is
  written to the calendar, says what happened, and can be undone; a change
  the calendar would refuse snaps back.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Phoenix.LiveView, only: [send_update: 3]
  import Tymeslot.Factory, only: [insert: 2]
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Ecto.Changeset
  alias Tymeslot.CalendarGrid.WriteGuardian
  alias Tymeslot.CalendarGrid.WriteQueue
  alias Tymeslot.CalendarMock
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimit
  alias Tymeslot.Security.RateLimiter
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

    assert %{start: "2026-10-15T11:00", end: "2026-10-15T12:00", editable: true, movable: true} =
             pushed(lv, id)

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

  test "undoing a resize of the end says when it ends again", %{lv: lv, review: review, id: id} do
    move(lv, id, "2026-10-14T10:00", "2026-10-14T11:30")
    assert_receive {:written, _uid, _resized}
    render(lv)

    lv |> element("#calendar-undo") |> render_click()

    uid = review.uid
    assert_receive {:written, ^uid, payload}, 1_000
    assert same?(payload.end_time, ~U[2026-10-14 10:00:00Z])
    assert has_element?(lv, "#calendar-toast", "Now ends at 11:00")
    refute has_element?(lv, "#calendar-toast", "Moved back")
  end

  test "undoing a resize of the start says when it starts again", %{
    lv: lv,
    review: review,
    id: id
  } do
    move(lv, id, "2026-10-14T10:30", "2026-10-14T11:00")
    assert_receive {:written, _uid, _resized}
    render(lv)

    lv |> element("#calendar-undo") |> render_click()

    uid = review.uid
    assert_receive {:written, ^uid, payload}, 1_000
    assert same?(payload.start_time, ~U[2026-10-14 09:00:00Z])
    assert has_element?(lv, "#calendar-toast", "Now starts at 10:00")
    refute has_element?(lv, "#calendar-toast", "Moved back")
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
    refute_receive {:written, _uid, _payload}, 100
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
      refute_receive {:written, _uid, _payload}, 100
    end
  end

  describe "when a later write of the same event fails" do
    test "the earlier, written change stays undoable", %{lv: lv, review: review, id: id} do
      move(lv, id, "2026-10-15T11:00", "2026-10-15T12:00")
      assert_receive {:written, _uid, _first}
      render(lv)

      Mox.stub(CalendarMock, :update_event, fn _uid, _payload, _context ->
        {:error, :provider_down}
      end)

      flush_pushes(lv)
      move(lv, id, "2026-10-16T11:00", "2026-10-16T12:00")
      await_original(lv, id, "2026-10-15T11:00")
      render(lv)

      test_pid = self()

      Mox.stub(CalendarMock, :update_event, fn uid, payload, _context ->
        send(test_pid, {:written, uid, payload})
        :ok
      end)

      lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})

      uid = review.uid
      assert_receive {:written, ^uid, payload}, 1_000
      assert same?(payload.start_time, ~U[2026-10-14 09:00:00Z])
    end
  end

  describe "when an undo's write fails" do
    test "the change it was taking back can be undone again, and the older one after it", %{
      lv: lv,
      review: review,
      id: id
    } do
      uid = review.uid
      move(lv, id, "2026-10-15T11:00", "2026-10-15T12:00")
      assert_receive {:written, ^uid, _first}
      render(lv)
      move(lv, id, "2026-10-16T11:00", "2026-10-16T12:00")
      assert_receive {:written, ^uid, _second}
      render(lv)

      Mox.stub(CalendarMock, :update_event, fn _uid, _payload, _context ->
        {:error, :provider_down}
      end)

      flush_pushes(lv)
      lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})
      await_original(lv, id, "2026-10-16T11:00")
      render(lv)

      test_pid = self()

      Mox.stub(CalendarMock, :update_event, fn uid, payload, _context ->
        send(test_pid, {:written, uid, payload})
        :ok
      end)

      lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})
      assert_receive {:written, ^uid, retried}, 1_000
      assert same?(retried.start_time, ~U[2026-10-15 10:00:00Z])
      render(lv)

      lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})
      assert_receive {:written, ^uid, older}, 1_000
      assert same?(older.start_time, ~U[2026-10-14 09:00:00Z])
    end
  end

  describe "a change the calendar refuses snaps back and writes nothing" do
    # The event `id` as the snap-back push draws it; nothing was written.
    defp snapped_back(lv, id) do
      assert_push_event(lv, "calendar:events", %{events: events})
      refute_receive {:written, _uid, _payload}, 100
      Enum.find(events, &(&1.id == id))
    end

    test "an event that is not in the window", %{lv: lv, id: id} do
      flush_pushes(lv)
      move(lv, "event-0", "2026-10-15T11:00", "2026-10-15T12:00")

      assert %{start: "2026-10-14T10:00"} = snapped_back(lv, id)
    end

    test "another organiser's event", %{lv: lv} do
      stranger = insert(:calendar_integration, is_active: true)
      theirs = event(stranger, "work", "Not yours", ~U[2026-10-15 09:00:00Z])
      flush_pushes(lv)

      move(lv, "event-#{theirs.id}", "2026-10-15T11:00", "2026-10-15T12:00")

      refute snapped_back(lv, "event-#{theirs.id}")
    end

    test "a booking", %{conn: conn, user: user} do
      meeting =
        insert(:meeting,
          organizer_user: user,
          title: "Intro call",
          start_time: ~U[2026-10-15 10:00:00Z],
          end_time: ~U[2026-10-15 10:30:00Z],
          status: "confirmed"
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      flush_pushes(lv)
      move(lv, "booking-#{meeting.id}", "2026-10-15T14:00", "2026-10-15T14:30")

      assert %{start: "2026-10-15T11:00"} = snapped_back(lv, "booking-#{meeting.id}")
    end

    test "the calendar copy of a booking", %{
      conn: conn,
      integration: integration
    } do
      copy = event(integration, "work", "Booked call", ~U[2026-10-15 13:00:00Z], 30)
      copy_id = "event-#{copy.id}"
      insert(:meeting, calendar_integration_id: integration.id, calendar_uid: copy.uid)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      flush_pushes(lv)
      move(lv, copy_id, "2026-10-15T16:00", "2026-10-15T16:30")

      assert %{start: "2026-10-15T14:00", editable: true, movable: false} =
               snapped_back(lv, copy_id)

      assert render(lv) =~ "This is a booking. Reschedule or cancel it from Bookings."
    end

    test "a move the rate limit refuses", %{lv: lv, user: user, id: id} do
      for _i <- 1..30, do: RateLimiter.check(:calendar_event_edit, user.id)
      flush_pushes(lv)

      move(lv, id, "2026-10-15T11:00", "2026-10-15T12:00")

      assert %{start: "2026-10-14T10:00"} = snapped_back(lv, id)
      assert render(lv) =~ "Too many edits. Please wait a moment."
    end

    test "an all-day event", %{conn: conn, integration: integration} do
      holiday =
        event(integration, "work", "Holiday", ~U[2026-10-16 00:00:00Z], 1440,
          all_day: true,
          start_date: ~D[2026-10-16],
          end_date: ~D[2026-10-17]
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      flush_pushes(lv)
      move(lv, "event-#{holiday.id}", "2026-10-17T10:00", "2026-10-17T11:00")

      assert %{all_day: true} = snapped_back(lv, "event-#{holiday.id}")
    end

    test "an end at or before the start", %{lv: lv, id: id} do
      flush_pushes(lv)
      move(lv, id, "2026-10-15T11:00", "2026-10-15T11:00")

      assert %{start: "2026-10-14T10:00"} = snapped_back(lv, id)
    end

    test "an end that is not text", %{lv: lv, id: id} do
      flush_pushes(lv)
      move(lv, id, "2026-10-15T11:00", nil)
      assert %{start: "2026-10-14T10:00"} = snapped_back(lv, id)

      move(lv, id, "2026-10-15T11:00", 42)
      assert %{start: "2026-10-14T10:00"} = snapped_back(lv, id)
      assert Process.alive?(lv.pid)
    end

    test "times that are not times", %{lv: lv, id: id} do
      flush_pushes(lv)
      move(lv, id, "not a time", "2026-10-15T11:00")

      assert %{start: "2026-10-14T10:00"} = snapped_back(lv, id)
    end

    test "a span of more than a week", %{lv: lv, id: id} do
      flush_pushes(lv)
      move(lv, id, "2026-10-15T09:00", "2026-10-23T09:00")

      assert %{start: "2026-10-14T10:00"} = snapped_back(lv, id)
    end

    test "a start outside the years the grid can show", %{lv: lv, id: id} do
      flush_pushes(lv)
      move(lv, id, "1800-01-01T10:00", "1800-01-01T11:00")

      assert %{start: "2026-10-14T10:00"} = snapped_back(lv, id)
    end

    test "a series member waits for the series choice, writing nothing", %{
      conn: conn,
      integration: integration
    } do
      standup =
        event(integration, "work", "Standup", ~U[2026-10-15 08:00:00Z], 30,
          recurring_event_id: "master-1"
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      flush_pushes(lv)
      move(lv, "event-#{standup.id}", "2026-10-15T11:00", "2026-10-15T11:30")

      assert has_element?(lv, "#calendar-series-scope", "Standup")
      assert %{start: "2026-10-15T11:00"} = snapped_back(lv, "event-#{standup.id}")
    end
  end

  describe "a second move while the series choice is open" do
    test "puts the first event back and asks about the second", %{
      conn: conn,
      integration: integration
    } do
      first =
        event(integration, "work", "Standup", ~U[2026-10-15 08:00:00Z], 30,
          recurring_event_id: "master-1"
        )

      second =
        event(integration, "work", "Retro", ~U[2026-10-16 08:00:00Z], 30,
          recurring_event_id: "master-2"
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      first_id = "event-#{first.id}"
      move(lv, first_id, "2026-10-15T11:00", "2026-10-15T11:30")
      flush_pushes(lv)

      move(lv, "event-#{second.id}", "2026-10-16T11:00", "2026-10-16T11:30")

      # The first event is drawn back at 09:00 (08:00 UTC) in London.
      assert_push_event(lv, "calendar:events", %{events: events})
      assert %{start: "2026-10-15T09:00"} = Enum.find(events, &(&1.id == first_id))

      assert has_element?(lv, "#calendar-series-scope", "Retro")
      refute has_element?(lv, "#calendar-series-scope", "Standup")
      refute_receive {:written, _uid, _payload}, 100
    end
  end

  test "a change from the start edge says when the event now starts", %{lv: lv, id: id} do
    move(lv, id, "2026-10-14T10:30", "2026-10-14T11:00")

    assert has_element?(lv, "#calendar-toast", "Now starts at 10:30")
  end

  describe "across a clock change" do
    test "a move keeps the event's length", %{conn: conn, integration: integration} do
      # Clocks in London go forward at 01:00 on 29 March 2026: 01:30 does not exist.
      talk = event(integration, "work", "Talk", ~U[2026-03-28 10:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=week&date=2026-03-28")

      move(lv, "event-#{talk.id}", "2026-03-29T00:30", "2026-03-29T01:30")

      uid = talk.uid
      assert_receive {:written, ^uid, payload}
      assert same?(payload.start_time, ~U[2026-03-29 00:30:00Z])
      assert same?(payload.end_time, ~U[2026-03-29 01:30:00Z])
    end
  end

  describe "undo after the event has changed" do
    test "writes nothing and says so", %{lv: lv, review: review, id: id} do
      move(lv, id, "2026-10-15T11:00", "2026-10-15T12:00")
      assert_receive {:written, _uid, _moved}
      eventually(fn -> assert same?(Repo.reload!(review).start_at, ~U[2026-10-15 10:00:00Z]) end)

      # A sync brings the event as it was changed elsewhere.
      review
      |> Changeset.change(
        start_at: ~U[2026-10-16 13:00:00.000000Z],
        end_at: ~U[2026-10-16 14:00:00.000000Z]
      )
      |> Repo.update!()

      flush_pushes(lv)
      send_update(lv.pid, CalendarSurface, id: "calendar", action: :events_updated)
      assert_push_event(lv, "calendar:events", %{reset: true, events: events}, 1_000)
      assert %{start: "2026-10-16T14:00"} = Enum.find(events, &(&1.id == id))

      lv |> element("#calendar-undo") |> render_click()

      assert has_element?(lv, "#calendar-toast", "That change can't be undone any more.")
      refute_receive {:written, _uid, _payload}, 100
    end

    test "that the rate limit refuses stays undoable", %{
      lv: lv,
      user: user,
      review: review,
      id: id
    } do
      move(lv, id, "2026-10-15T11:00", "2026-10-15T12:00")
      assert_receive {:written, _uid, _moved}
      for _i <- 1..30, do: RateLimiter.check(:calendar_event_edit, user.id)

      lv |> element("#calendar-undo") |> render_click()

      refute_receive {:written, _uid, _payload}, 100

      # Still undoable once the limiter lets the organiser edit again.
      RateLimit.clear("calendar_event_edit:#{user.id}")
      lv |> element("#calendar-undo") |> render_click()

      uid = review.uid
      assert_receive {:written, ^uid, payload}, 1_000
      assert same?(payload.start_time, ~U[2026-10-14 09:00:00Z])
    end
  end

  describe "a failed write's toast" do
    test "is dismissed only for the event that failed", %{
      conn: conn,
      integration: integration,
      review: review
    } do
      other = event(integration, "work", "Retro", ~U[2026-10-16 09:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      hold_writes()

      review_id = "event-#{review.id}"
      move(lv, review_id, "2026-10-15T11:00", "2026-10-15T12:00")
      assert_receive {:write_started, writer, _uid, _payload}
      move(lv, "event-#{other.id}", "2026-10-16T14:00", "2026-10-16T15:00")
      assert_receive {:write_started, other_writer, _uid, _payload}
      assert review.uid != other.uid

      send(writer, {:answer, {:error, :provider_down}})

      await_original(lv, review_id)

      assert has_element?(lv, "#calendar-toast", "Moved to Fri 16 Oct, 14:00")
      send(other_writer, {:answer, :ok})
    end
  end

  # Waits for the push that draws `id` back at 10:00, where it began.
  defp await_original(lv, id, start \\ "2026-10-14T10:00") do
    assert_push_event(lv, "calendar:events", %{events: events}, 1_000)

    unless match?(%{start: ^start}, Enum.find(events, &(&1.id == id))),
      do: await_original(lv, id, start)
  end
end
