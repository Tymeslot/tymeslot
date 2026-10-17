defmodule Tymeslot.CalendarGrid.ScheduledDeleteTest do
  @moduledoc """
  A delete made from the calendar waits out its undo window as a job: Undo
  cancels it before anything reaches the calendar, and once it runs the
  organiser's open calendars hear how it went.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.ScheduledDelete
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Workers.CalendarEventDeleteWorker

  setup :verify_on_exit!

  setup do
    user = insert(:user)

    caldav =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

    event =
      insert(:provider_calendar_event,
        calendar_integration: caldav,
        uid: "dentist-1",
        summary: "Dentist",
        provider: "caldav",
        provider_calendar_id: "/cal/",
        provider_event_id: "/cal/dentist.ics",
        start_at: ~U[2026-10-15 09:00:00.000000Z],
        end_at: ~U[2026-10-15 10:00:00.000000Z],
        all_day: false,
        sync_state: "synced"
      )

    Phoenix.PubSub.subscribe(Tymeslot.PubSub, "calendar_events:#{user.id}")
    %{user: user, caldav: caldav, event: event}
  end

  test "schedules the delete behind the undo window", %{user: user, event: event} do
    assert {:ok, token} = CalendarGrid.schedule_delete(user.id, event, :occurrence, [])

    assert_enqueued(
      worker: CalendarEventDeleteWorker,
      args: %{"uid" => "dentist-1", "scope" => "occurrence", "user_id" => user.id},
      scheduled_at: {DateTime.add(DateTime.utc_now(), ScheduledDelete.undo_delay()), delta: 5}
    )

    assert is_integer(token)
  end

  test "undo cancels it before anything reaches the calendar", %{user: user, event: event} do
    {:ok, token} = CalendarGrid.schedule_delete(user.id, event, :occurrence, [])

    assert CalendarGrid.cancel_scheduled_delete(user.id, token) == :ok
    refute_enqueued(worker: CalendarEventDeleteWorker)
    assert %{success: 0} = Oban.drain_queue(queue: :calendar_events, with_scheduled: true)
  end

  test "only the organiser who deleted can undo", %{user: user, event: event} do
    {:ok, token} = CalendarGrid.schedule_delete(user.id, event, :occurrence, [])

    assert CalendarGrid.cancel_scheduled_delete(insert(:user).id, token) == {:error, :too_late}
    assert_enqueued(worker: CalendarEventDeleteWorker)
  end

  test "once run, it deletes the event and says so, and can no longer be undone", %{
    user: user,
    caldav: caldav,
    event: event
  } do
    expect(Tymeslot.CalendarMock, :delete_event, fn "dentist-1", _context, _opts -> :ok end)
    {:ok, token} = CalendarGrid.schedule_delete(user.id, event, :occurrence, [])

    assert %{success: 1} = Oban.drain_queue(queue: :calendar_events, with_scheduled: true)

    user_id = user.id
    assert_receive {:calendar_delete_result, ^user_id, ^token, :deleted}
    assert ProviderCalendarEventQueries.get_by_uid(caldav.id, "dentist-1") == {:error, :not_found}
    assert CalendarGrid.cancel_scheduled_delete(user.id, token) == {:error, :too_late}
  end

  test "a delete the calendar refuses is reported as not done", %{user: user, event: event} do
    expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
      {:error, :forbidden}
    end)

    {:ok, token} = CalendarGrid.schedule_delete(user.id, event, :occurrence, delay: 0)
    Oban.drain_queue(queue: :calendar_events, with_scheduled: true)

    assert_receive {:calendar_delete_result, _user_id, ^token, outcome}
    assert outcome != :deleted
  end

  describe "delete_notice/2" do
    test "a plain event tells nobody", %{user: user, event: event} do
      assert CalendarGrid.delete_notice(user.id, event) == :silent
    end

    test "an event with guests the organiser invited would tell them", %{
      user: user,
      caldav: caldav
    } do
      event =
        insert(:provider_calendar_event,
          calendar_integration: caldav,
          provider: "caldav",
          attendees: [
            %{"email" => "ada@example.com"},
            %{"email" => "grace@example.com"}
          ]
        )

      assert CalendarGrid.delete_notice(user.id, event) == {:notifies, {:attendees, 2}}
    end
  end
end
