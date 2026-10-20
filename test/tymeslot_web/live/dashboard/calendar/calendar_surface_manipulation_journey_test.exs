defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceManipulationJourneyTest do
  @moduledoc """
  The organiser changes their week on the calendar: moves an event to
  another day, stretches it, takes the stretch back with Ctrl Z, deletes
  another event and changes their mind, then deletes it for good. A repeating
  event is moved for one occurrence only, and that too is taken back. Every
  change reaches the calendar provider, and the grid always ends on what the
  server holds.
  """

  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.CalendarMock
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventDeleteWorker

  # Whatever the grid was pushed before this step is not this step's answer.
  defp flush_pushes(lv) do
    receive do
      {_ref, {:push_event, _event, _payload}} -> flush_pushes(lv)
    after
      50 -> :ok
    end
  end

  defp hook(lv, name, params) do
    flush_pushes(lv)
    lv |> element("#calendar-canvas") |> render_hook(name, params)
  end

  defp click(lv, selector) do
    flush_pushes(lv)
    lv |> element(selector) |> render_click()
  end

  defp pushed(lv) do
    assert_push_event(lv, "calendar:events", %{events: events})
    Map.new(events, &{&1.id, &1})
  end

  # The window as the grid ends up holding it: the last push of a step.
  defp last_pushed(lv, last \\ nil) do
    receive do
      {_ref, {:push_event, "calendar:events", %{events: events}}} ->
        last_pushed(lv, Map.new(events, &{&1.id, &1}))
    after
      if(last, do: 100, else: 1_000) -> last || flunk("the grid was not sent the window")
    end
  end

  # The provider was written to, and the write has been recorded locally:
  # a successful write answers without re-sending the window, so the cached
  # row is what says the write is over.
  defp written(row, start_at, end_at) do
    uid = row.uid
    assert_receive {:written, ^uid, payload}, 1_000

    eventually(fn ->
      saved = Repo.reload!(row)
      assert at?(saved.start_at, start_at)
      assert at?(saved.end_at, end_at)
    end)

    payload
  end

  defp google_event(row) do
    %{
      "id" => row.uid,
      "iCalUID" => row.uid,
      "status" => "confirmed",
      "summary" => row.summary,
      "start" => %{"dateTime" => DateTime.to_iso8601(row.start_at)},
      "end" => %{"dateTime" => DateTime.to_iso8601(row.end_at)}
    }
  end

  defp at?(%DateTime{} = actual, expected), do: DateTime.compare(actual, expected) == :eq

  setup %{conn: conn} do
    context = owner(conn)
    test_pid = self()

    Mox.stub(CalendarMock, :update_event, fn uid, payload, _context ->
      send(test_pid, {:written, uid, payload})
      :ok
    end)

    # The sync job the writes leave behind finds nothing new at the provider.
    Mox.stub(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
      {:ok, %{events: [], next_sync_token: "next"}}
    end)

    # Its sweep lists what the calendar holds, which is what the cache holds.
    Mox.stub(GoogleCalendarAPIMock, :list_events, fn integration, calendar, _from, _to ->
      rows =
        Repo.all(
          from(e in ProviderCalendarEventSchema,
            where:
              e.calendar_integration_id == ^integration.id and e.provider_calendar_id == ^calendar
          )
        )

      {:ok, Enum.map(rows, &google_event/1)}
    end)

    Mox.stub(CalendarMock, :delete_event, fn uid, _context, _opts ->
      send(test_pid, {:deleted, uid})
      :ok
    end)

    context
  end

  test "move, resize, undo and delete", %{conn: conn, integration: integration} do
    review = event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    dentist = event(integration, "family", "Dentist", ~U[2026-10-16 13:00:00Z])
    review_id = "event-#{review.id}"
    dentist_id = "event-#{dentist.id}"

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    # The grid is told which events can be dragged.
    hook(lv, "calendar:ready", %{})
    assert_reply(lv, %{events: events})
    assert %{editable: true} = Enum.find(events, &(&1.id == review_id))

    # Drag Design review to Thursday 11:00.
    hook(lv, "calendar:move", %{
      "id" => review_id,
      "start" => "2026-10-15T11:00",
      "end" => "2026-10-15T12:00"
    })

    assert %{start: "2026-10-15T11:00"} = pushed(lv)[review_id]
    assert has_element?(lv, "#calendar-toast", "Moved to Thu 15 Oct, 11:00")
    payload = written(review, ~U[2026-10-15 10:00:00Z], ~U[2026-10-15 11:00:00Z])
    assert at?(payload.end_time, ~U[2026-10-15 11:00:00Z])

    # Stretch it to 12:30.
    hook(lv, "calendar:move", %{
      "id" => review_id,
      "start" => "2026-10-15T11:00",
      "end" => "2026-10-15T12:30"
    })

    assert %{end: "2026-10-15T12:30"} = pushed(lv)[review_id]
    assert has_element?(lv, "#calendar-toast", "Now ends at 12:30")
    written(review, ~U[2026-10-15 10:00:00Z], ~U[2026-10-15 11:30:00Z])

    # Ctrl Z takes back the stretch, and only the stretch.
    hook(lv, "calendar:undo", %{})

    assert %{start: "2026-10-15T11:00", end: "2026-10-15T12:00"} = pushed(lv)[review_id]
    assert has_element?(lv, "#calendar-toast", "Now ends at 12:00")
    payload = written(review, ~U[2026-10-15 10:00:00Z], ~U[2026-10-15 11:00:00Z])
    assert at?(payload.end_time, ~U[2026-10-15 11:00:00Z])

    # Delete the dentist from its preview, then change one's mind.
    hook(lv, "calendar:open", %{"id" => dentist_id})
    click(lv, "#calendar-preview-delete")

    refute Map.has_key?(pushed(lv), dentist_id)
    assert has_element?(lv, "#calendar-toast", "Deleted “Dentist”")
    assert_enqueued(worker: CalendarEventDeleteWorker, args: %{"uid" => dentist.uid})

    click(lv, "#calendar-undo")

    assert Map.has_key?(pushed(lv), dentist_id)
    assert has_element?(lv, "#calendar-toast", "“Dentist” is back")
    refute_enqueued(worker: CalendarEventDeleteWorker)
    refute_received {:deleted, _uid}

    # Delete it with the Delete key, and let the delete run for good.
    hook(lv, "calendar:delete", %{"id" => dentist_id})
    refute Map.has_key?(pushed(lv), dentist_id)
    assert_enqueued(worker: CalendarEventDeleteWorker, args: %{"uid" => dentist.uid})
    refute_received {:deleted, _uid}

    [job] = all_enqueued(worker: CalendarEventDeleteWorker)

    # The window has passed: the queue runs the delete (the jobs the writes
    # left beside it are not what is asserted on).
    assert %{failure: 0} = Oban.drain_queue(queue: :calendar_events, with_scheduled: true)
    assert Repo.reload!(job).state == "completed"

    dentist_uid = dentist.uid
    assert_received {:deleted, ^dentist_uid}

    refute Repo.get(ProviderCalendarEventSchema, dentist.id)

    # The grid follows the delete. The first Ctrl Z says it is too late to
    # bring the dentist back and writes nothing.
    render(lv)
    hook(lv, "calendar:undo", %{})

    assert has_element?(
             lv,
             "#calendar-toast",
             "Too late to undo: “Dentist” has already been deleted."
           )

    # The next one reaches the earlier move of Design review.
    hook(lv, "calendar:undo", %{})

    pushes = last_pushed(lv)
    assert %{start: "2026-10-14T10:00"} = pushes[review_id]
    refute Map.has_key?(pushes, dentist_id)
    assert has_element?(lv, "#calendar-toast", "Moved back to Wed 14 Oct, 10:00")
    written(review, ~U[2026-10-14 09:00:00Z], ~U[2026-10-14 10:00:00Z])
  end

  test "one occurrence of a repeating event moves, then Ctrl Z puts it back", %{
    conn: conn,
    integration: integration
  } do
    standup =
      event(integration, "work", "Standup", ~U[2026-10-14 08:30:00Z], 15,
        recurring_event_id: "standup-series",
        uid: "standup-series_20261014T083000Z"
      )

    id = "event-#{standup.id}"
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    hook(lv, "calendar:move", %{
      "id" => id,
      "start" => "2026-10-14T10:00",
      "end" => "2026-10-14T10:15"
    })

    # The move shows meanwhile; nothing is written until the choice is made.
    assert %{start: "2026-10-14T10:00"} = pushed(lv)[id]
    assert has_element?(lv, "#calendar-series-scope", "Standup")
    refute_received {:written, _uid, _payload}

    hook(lv, "calendar:choose_scope", %{"scope" => "this_only"})

    refute has_element?(lv, "#calendar-series-scope")
    assert has_element?(lv, "#calendar-undo")
    payload = written(standup, ~U[2026-10-14 09:00:00Z], ~U[2026-10-14 09:15:00Z])
    assert at?(payload.start_time, ~U[2026-10-14 09:00:00Z])

    hook(lv, "calendar:undo", %{})

    assert %{start: "2026-10-14T09:30"} = pushed(lv)[id]
    payload = written(standup, ~U[2026-10-14 08:30:00Z], ~U[2026-10-14 08:45:00Z])
    assert at?(payload.start_time, ~U[2026-10-14 08:30:00Z])
  end
end
