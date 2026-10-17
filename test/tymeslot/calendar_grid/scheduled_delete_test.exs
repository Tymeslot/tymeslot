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
  alias Tymeslot.Repo
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

  test "a delete the calendar refuses is queued for the next sync and says so", %{
    user: user,
    event: event
  } do
    expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
      {:error, :forbidden}
    end)

    {:ok, token} = CalendarGrid.schedule_delete(user.id, event, :occurrence, delay: 0)
    Oban.drain_queue(queue: :calendar_events, with_scheduled: true)

    assert_receive {:calendar_delete_result, _user_id, ^token, {:queued, :forbidden}}
  end

  test "a delete the calendar will never accept is reported as failed", %{
    user: user,
    event: event
  } do
    expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
      {:error, :unauthorized}
    end)

    {:ok, token} = CalendarGrid.schedule_delete(user.id, event, :occurrence, delay: 0)
    Oban.drain_queue(queue: :calendar_events, with_scheduled: true)

    assert_receive {:calendar_delete_result, _user_id, ^token, {:failed, :unauthorized}}
  end

  test "a group booking that gained seats during the window is not deleted", %{
    user: user,
    caldav: caldav
  } do
    meeting = insert(:meeting, organizer_user: user, organizer_user_id: user.id, capacity: 2)
    insert(:participant, meeting: meeting)

    event =
      insert(:provider_calendar_event,
        calendar_integration: caldav,
        uid: meeting.calendar_uid,
        provider: "caldav"
      )

    {:ok, token} = CalendarGrid.schedule_delete(user.id, event, :occurrence, delay: 0)
    assert %{success: 1} = Oban.drain_queue(queue: :calendar_events, with_scheduled: true)

    assert_receive {:calendar_delete_result, _user_id, ^token, {:failed, :group_booking}}
    assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)
  end

  describe "pending_deletes/1" do
    test "lists the user's waiting deletes, not another user's, cancelled or finished ones", %{
      user: user,
      caldav: caldav,
      event: event
    } do
      second = insert(:provider_calendar_event, calendar_integration: caldav, provider: "caldav")
      third = insert(:provider_calendar_event, calendar_integration: caldav, provider: "caldav")
      other = insert(:user)

      {:ok, first_token} = CalendarGrid.schedule_delete(user.id, event, :occurrence, [])
      {:ok, second_token} = CalendarGrid.schedule_delete(user.id, second, :series, [])
      {:ok, _other_token} = CalendarGrid.schedule_delete(other.id, third, :occurrence, [])

      pending = CalendarGrid.pending_deletes(user.id)
      assert Enum.sort(Enum.map(pending, & &1.token)) == Enum.sort([first_token, second_token])

      first = Enum.find(pending, &(&1.token == first_token))
      assert first.uid == "dentist-1"
      assert first.calendar_integration_id == caldav.id
      assert first.scope == :occurrence
      assert first.provider_event_id == "/cal/dentist.ics"
      assert %DateTime{} = first.scheduled_at

      assert Enum.find(pending, &(&1.token == second_token)).scope == :series

      assert CalendarGrid.cancel_scheduled_delete(user.id, first_token) == :ok
      assert [%{token: ^second_token}] = CalendarGrid.pending_deletes(user.id)

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)
      Oban.drain_queue(queue: :calendar_events, with_scheduled: true, queue_opts: [])
      assert CalendarGrid.pending_deletes(user.id) == []
    end
  end

  describe "running a delete directly" do
    defp run_delete(user, event, scope \\ :occurrence, attempt) do
      {:ok, token} = CalendarGrid.schedule_delete(user.id, event, scope, [])
      job = Repo.get!(Oban.Job, token)
      {token, ScheduledDelete.perform(%{job | attempt: attempt, max_attempts: 3})}
    end

    test "a rate-limited delete is snoozed, not reported", %{user: user, event: event} do
      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, {:rate_limited, 30}}
      end)

      assert {_token, {:snooze, 30}} = run_delete(user, event, 1)
      refute_receive {:calendar_delete_result, _, _, _}
    end

    test "a transient failure retries, and is reported only on the last attempt", %{user: user} do
      google = insert(:calendar_integration, user: user, provider: "google")

      occurrence =
        insert(:provider_calendar_event,
          calendar_integration: google,
          provider: "google",
          uid: "series-1@google.com_20260601T090000Z",
          provider_calendar_id: "primary",
          provider_event_id: "series-1_20260601T090000Z",
          recurring_event_id: "series-1"
        )

      expect(Tymeslot.CalendarMock, :delete_event, 2, fn _uid, _context, _opts ->
        {:error, :timeout}
      end)

      assert {_token, {:error, :timeout}} = run_delete(user, occurrence, 1)
      refute_receive {:calendar_delete_result, _, _, _}

      {token, :ok} = run_delete(user, occurrence, 3)
      assert_receive {:calendar_delete_result, _user_id, ^token, {:failed, :timeout}}
    end

    test "not found on a retry means it is already gone", %{user: user, event: event} do
      expect(Tymeslot.CalendarMock, :delete_event, 2, fn _uid, _context, _opts ->
        {:error, :not_found}
      end)

      {token, :ok} = run_delete(user, event, 2)
      assert_receive {:calendar_delete_result, _user_id, ^token, :deleted}

      {token, :ok} = run_delete(user, event, 1)
      assert_receive {:calendar_delete_result, _user_id, ^token, {:failed, :not_found}}
    end

    test "an event whose cached row is gone counts as deleted", %{
      user: user,
      event: event
    } do
      {:ok, _row} = Repo.delete(event)

      {token, :ok} = run_delete(user, event, 1)
      assert_receive {:calendar_delete_result, _user_id, ^token, :deleted}
    end
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

    test "an event linked to a meeting by uid cancels it", %{
      user: user,
      caldav: caldav,
      event: event
    } do
      insert(:meeting,
        organizer_user: user,
        organizer_user_id: user.id,
        calendar_integration_id: caldav.id,
        calendar_uid: event.uid
      )

      assert CalendarGrid.delete_notice(user.id, event) == {:notifies, :booking}
    end

    test "an event linked to a meeting by provider event id cancels it", %{
      user: user,
      caldav: caldav,
      event: event
    } do
      insert(:meeting,
        organizer_user: user,
        organizer_user_id: user.id,
        calendar_integration_id: caldav.id,
        provider_event_id: event.provider_event_id
      )

      assert CalendarGrid.delete_notice(user.id, event) == {:notifies, :booking}
    end
  end
end
