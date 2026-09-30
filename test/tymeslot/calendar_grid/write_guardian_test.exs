defmodule Tymeslot.CalendarGrid.WriteGuardianTest do
  @moduledoc """
  A write guardian stopped by a shutdown (a deploy, a restart) before it has
  finished the grid's queue saves the edits still waiting for the next
  sync where the calendar has an offline queue, and logs, at error level,
  how many it could not.

  The test process stands in for the grid's LiveView: it hands its queue to
  a guardian as the grid does, and the guardian is then stopped the way the
  application's supervisor stops it.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  alias Tymeslot.CalendarGrid.WriteGuardian
  alias Tymeslot.CalendarGrid.WriteQueue
  alias Tymeslot.Integrations.Calendar.CalDAV.QueueQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Test.LogCapture

  setup do
    LogCapture.attach()
    {:ok, user: insert(:user)}
  end

  test "saves the edit waiting behind a running one for the next CalDAV sync", %{user: user} do
    caldav =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

    event = cached_event(caldav, "caldav")
    guardian = guard(user, event)

    shut_down(guardian)

    # The running write's change is taken as made, the waiting one on top.
    assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)
    assert %{summary: "Renamed", location: "Room 9"} = row
    assert [%{uid: uid, sync_state: state}] = QueueQueries.list_pending(caldav.id)
    assert uid == event.uid
    refute state == "synced"
    refute_receive {:captured_log, %{level: :error}}, 100
  end

  test "logs the edit it cannot save where the calendar has no offline queue", %{user: user} do
    google = insert(:calendar_integration, user: user, provider: "google")
    event = cached_event(google, "google")
    guardian = guard(user, event)

    shut_down(guardian)

    user_id = user.id

    assert_receive {:captured_log, %{level: :error, meta: %{user_id: ^user_id, lost_writes: 1}}},
                   1_000

    assert {:ok, %{location: "Room 1"}} =
             ProviderCalendarEventQueries.get_by_uid(google.id, event.uid)
  end

  defp cached_event(integration, provider) do
    insert(:provider_calendar_event,
      calendar_integration: integration,
      uid: "event-#{System.unique_integer([:positive])}",
      summary: "Standup",
      location: "Room 1",
      provider: provider,
      provider_calendar_id: "/cal/",
      provider_event_id: "/cal/standup.ics",
      start_at: ~U[2026-06-01 09:00:00.000000Z],
      end_at: ~U[2026-06-01 10:00:00.000000Z],
      all_day: false,
      sync_state: "synced"
    )
  end

  # A rename in flight, which never answers, and an edit waiting behind it,
  # handed to a guardian as the grid hands its queue.
  defp guard(user, event) do
    {queue, [{:start, _running, _event}]} =
      WriteQueue.update(WriteQueue.new(), event, %{summary: "Renamed"}, [])

    {queue, []} = WriteQueue.update(queue, event, %{location: "Room 9"}, [])

    :ok = WriteGuardian.mirror(queue, user.id)
    guardian = WriteGuardian.whereis(self())
    assert is_pid(guardian)
    # The mirror is a cast; a call behind it makes sure it has landed.
    _state = :sys.get_state(guardian)
    guardian
  end

  defp shut_down(guardian) do
    ref = Process.monitor(guardian)
    :ok = DynamicSupervisor.terminate_child(WriteGuardian.supervisor(), guardian)
    assert_receive {:DOWN, ^ref, :process, ^guardian, :shutdown}, 1_000
  end
end
