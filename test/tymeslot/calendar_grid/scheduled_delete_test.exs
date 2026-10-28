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

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.CalendarGrid.ScheduledDelete
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
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
    assert {:ok, token} = Changes.schedule_delete(user.id, event, :occurrence, [])

    assert_enqueued(
      worker: CalendarEventDeleteWorker,
      args: %{"uid" => "dentist-1", "scope" => "occurrence", "user_id" => user.id},
      scheduled_at: {DateTime.add(DateTime.utc_now(), ScheduledDelete.undo_delay()), delta: 5}
    )

    assert is_integer(token)
  end

  test "undo cancels it before anything reaches the calendar", %{user: user, event: event} do
    {:ok, token} = Changes.schedule_delete(user.id, event, :occurrence, [])

    assert Changes.cancel_scheduled_delete(user.id, token) == :ok
    refute_enqueued(worker: CalendarEventDeleteWorker)
    assert %{success: 0} = Oban.drain_queue(queue: :calendar_events, with_scheduled: true)
  end

  test "only the organiser who deleted can undo", %{user: user, event: event} do
    {:ok, token} = Changes.schedule_delete(user.id, event, :occurrence, [])

    assert Changes.cancel_scheduled_delete(insert(:user).id, token) == {:error, :too_late}
    assert_enqueued(worker: CalendarEventDeleteWorker)
  end

  test "once run, it deletes the event and says so, and can no longer be undone", %{
    user: user,
    caldav: caldav,
    event: event
  } do
    expect(Tymeslot.CalendarMock, :delete_event, fn "dentist-1", _context, _opts -> :ok end)
    {:ok, token} = Changes.schedule_delete(user.id, event, :occurrence, [])

    assert %{success: 1} = Oban.drain_queue(queue: :calendar_events, with_scheduled: true)

    user_id = user.id
    assert_receive {:calendar_delete_result, ^user_id, ^token, :deleted}
    assert ProviderCalendarEventQueries.get_by_uid(caldav.id, "dentist-1") == {:error, :not_found}
    assert Changes.cancel_scheduled_delete(user.id, token) == {:error, :too_late}
  end

  test "a delete the calendar refuses is queued for the next sync and says so", %{
    user: user,
    event: event
  } do
    expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
      {:error, :forbidden}
    end)

    {:ok, token} = Changes.schedule_delete(user.id, event, :occurrence, delay: 0)
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

    {:ok, token} = Changes.schedule_delete(user.id, event, :occurrence, delay: 0)
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

    {:ok, token} = Changes.schedule_delete(user.id, event, :occurrence, delay: 0)
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

      {:ok, first_token} = Changes.schedule_delete(user.id, event, :occurrence, [])
      {:ok, second_token} = Changes.schedule_delete(user.id, second, :series, [])
      {:ok, _other_token} = Changes.schedule_delete(other.id, third, :occurrence, [])

      pending = Changes.pending_deletes(user.id)
      assert Enum.sort(Enum.map(pending, & &1.token)) == Enum.sort([first_token, second_token])

      first = Enum.find(pending, &(&1.token == first_token))
      assert first.uid == "dentist-1"
      assert first.calendar_integration_id == caldav.id
      assert first.scope == :occurrence
      assert first.provider_event_id == "/cal/dentist.ics"
      assert %DateTime{} = first.scheduled_at

      assert Enum.find(pending, &(&1.token == second_token)).scope == :series

      assert Changes.cancel_scheduled_delete(user.id, first_token) == :ok
      assert [%{token: ^second_token}] = Changes.pending_deletes(user.id)

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)
      Oban.drain_queue(queue: :calendar_events, with_scheduled: true, queue_opts: [])
      assert Changes.pending_deletes(user.id) == []
    end
  end

  describe "telling the organiser's other calendars" do
    test "scheduling a delete announces its address and scope", %{user: user, event: event} do
      {:ok, token} = Changes.schedule_delete(user.id, event, :series, [])

      assert_receive {:calendar_delete_scheduled, user_id, ^token, address, :series}
      assert user_id == user.id
      assert address.uid == "dentist-1"
      assert address.calendar_integration_id == event.calendar_integration_id
      assert address.provider_event_id == "/cal/dentist.ics"
    end

    test "undoing it announces the cancellation", %{user: user, event: event} do
      {:ok, token} = Changes.schedule_delete(user.id, event, :occurrence, [])

      assert Changes.cancel_scheduled_delete(user.id, token) == :ok
      assert_receive {:calendar_delete_cancelled, user_id, ^token}
      assert user_id == user.id
    end

    test "a refused or repeated undo announces nothing", %{user: user, event: event} do
      {:ok, token} = Changes.schedule_delete(user.id, event, :occurrence, [])
      assert Changes.cancel_scheduled_delete(user.id, token) == :ok
      assert_receive {:calendar_delete_cancelled, _user_id, ^token}

      assert Changes.cancel_scheduled_delete(user.id, token) == {:error, :cancelled}
      refute_receive {:calendar_delete_cancelled, _user_id, ^token}

      {:ok, other} = Changes.schedule_delete(user.id, event, :occurrence, [])
      assert Changes.cancel_scheduled_delete(insert(:user).id, other) == {:error, :too_late}
      refute_receive {:calendar_delete_cancelled, _user_id, ^other}
    end

    test "a job that never existed is too late", %{user: user} do
      assert Changes.cancel_scheduled_delete(user.id, 0) == {:error, :too_late}
    end
  end

  describe "pending_deletes/1 for a confirmed delete" do
    test "is never undoable, even after the job is put back to wait", %{user: user, event: event} do
      {:ok, token} =
        Changes.schedule_delete(user.id, event, :occurrence,
          delay: 0,
          notify_attendees: true
        )

      assert [%{token: ^token, undoable?: false}] = Changes.pending_deletes(user.id)

      # A rate-limited run is snoozed: back to "scheduled", still not undoable.
      Repo.update_all(from(j in Oban.Job, where: j.id == ^token), set: [state: "scheduled"])
      assert [%{token: ^token, undoable?: false}] = Changes.pending_deletes(user.id)
    end

    test "a retryable delete is still pending, and not undoable", %{user: user, event: event} do
      {:ok, token} = Changes.schedule_delete(user.id, event, :occurrence, [])
      Repo.update_all(from(j in Oban.Job, where: j.id == ^token), set: [state: "retryable"])

      assert [%{token: ^token, undoable?: false}] = Changes.pending_deletes(user.id)
    end
  end

  describe "pending_deletes/1 while a delete runs" do
    test "lists it, but no longer as undoable", %{user: user, event: event} do
      {:ok, token} = Changes.schedule_delete(user.id, event, :occurrence, [])
      assert [%{undoable?: true}] = Changes.pending_deletes(user.id)

      Repo.update_all(from(j in Oban.Job, where: j.id == ^token), set: [state: "executing"])

      assert [%{token: ^token, undoable?: false}] = Changes.pending_deletes(user.id)
      assert Changes.cancel_scheduled_delete(user.id, token) == {:error, :too_late}
    end
  end

  describe "running a delete directly" do
    # A 404 counts as already gone only once no writable calendar of the
    # account has the event (`Tymeslot.Integrations.Calendar.Events`).
    setup do
      stub(Tymeslot.CalendarMock, :fetch_event, fn _ref, _context -> {:error, :not_found} end)
      :ok
    end

    defp run_delete(user, event, attempt, opts \\ []) do
      meta = Keyword.get(opts, :meta, %{})
      scope = Keyword.get(opts, :scope, :occurrence)
      {:ok, token} = Changes.schedule_delete(user.id, event, scope, [])
      job = Repo.get!(Oban.Job, token)
      job = %{job | attempt: attempt, max_attempts: 3, meta: meta}
      {token, ScheduledDelete.perform(job)}
    end

    defp google_occurrence(user, stamp \\ "20260601T090000Z") do
      google =
        Repo.get_by(CalendarIntegrationSchema,
          user_id: user.id,
          provider: "google"
        ) || insert(:calendar_integration, user: user, provider: "google")

      insert(:provider_calendar_event,
        calendar_integration: google,
        provider: "google",
        uid: "series-1@google.com_#{stamp}",
        provider_calendar_id: "primary",
        provider_event_id: "series-1_#{stamp}",
        recurring_event_id: "series-1"
      )
    end

    test "a rate-limited delete is snoozed, not reported", %{user: user, event: event} do
      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, {:rate_limited, 30}}
      end)

      assert {_token, {:snooze, 30}} = run_delete(user, event, 1)
      refute_receive {:calendar_delete_result, _, _, _}
    end

    for reason <- [
          :timeout,
          :network_error,
          :server_error,
          :service_unavailable,
          {:http_error, 503}
        ] do
      test "a #{inspect(reason)} failure retries, and is reported only on the last attempt", %{
        user: user
      } do
        occurrence = google_occurrence(user)
        reason = unquote(Macro.escape(reason))

        expect(Tymeslot.CalendarMock, :delete_event, 2, fn _uid, _context, _opts ->
          {:error, reason}
        end)

        assert {_token, {:error, ^reason}} = run_delete(user, occurrence, 1)
        refute_receive {:calendar_delete_result, _, _, _}

        {token, :ok} = run_delete(user, occurrence, 3)
        assert_receive {:calendar_delete_result, _user_id, ^token, {:failed, ^reason}}
      end
    end

    test "a refusal is reported at once, without a retry", %{user: user} do
      occurrence = google_occurrence(user)

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :forbidden}
      end)

      {token, :ok} = run_delete(user, occurrence, 1)
      assert_receive {:calendar_delete_result, _user_id, ^token, {:failed, :forbidden}}
    end

    test "an open circuit snoozes for the breaker's recovery time", %{user: user} do
      occurrence = google_occurrence(user)

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :circuit_open}
      end)

      recovery =
        div(
          CalendarCircuitBreaker.get_config(:google).recovery_timeout,
          1000
        )

      assert {_token, {:snooze, ^recovery}} = run_delete(user, occurrence, 1)
      refute_receive {:calendar_delete_result, _, _, _}
    end

    test "gives up on a rate limit after five snoozes", %{user: user, event: event} do
      expect(Tymeslot.CalendarMock, :delete_event, 2, fn _uid, _context, _opts ->
        {:error, {:rate_limited, 30}}
      end)

      assert {_token, {:snooze, 30}} = run_delete(user, event, 1, meta: %{"snoozed" => 4})

      {token, :ok} = run_delete(user, event, 1, meta: %{"snoozed" => 5})
      assert_receive {:calendar_delete_result, _user_id, ^token, {:failed, :rate_limited}}
    end

    test "a series delete whose clicked occurrence is gone still deletes the rest", %{
      user: user
    } do
      clicked = google_occurrence(user)
      sibling = google_occurrence(user, "20260608T090000Z")
      {:ok, _row} = Repo.delete(clicked)

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, opts ->
        assert opts[:provider_event_id] == "series-1"
        :ok
      end)

      {token, :ok} = run_delete(user, clicked, 1, scope: :series)
      assert_receive {:calendar_delete_result, _user_id, ^token, :deleted}

      assert ProviderCalendarEventQueries.get_by_uid(sibling.calendar_integration_id, sibling.uid) ==
               {:error, :not_found}
    end

    test "an occurrence delete whose row is gone is deleted without asking the calendar", %{
      user: user
    } do
      clicked = google_occurrence(user)
      {:ok, _row} = Repo.delete(clicked)

      {token, :ok} = run_delete(user, clicked, 1)
      assert_receive {:calendar_delete_result, _user_id, ^token, :deleted}
    end

    test "the worker allows three attempts" do
      assert CalendarEventDeleteWorker.new(%{}).changes.max_attempts == 3
    end

    test "not found means it is already gone, on any attempt", %{user: user, event: event} do
      # The first attempt purges the row, so a later one never asks again.
      expect(Tymeslot.CalendarMock, :delete_event, 1, fn _uid, _context, _opts ->
        {:error, :not_found}
      end)

      {token, :ok} = run_delete(user, event, 2)
      assert_receive {:calendar_delete_result, _user_id, ^token, :deleted}

      {token, :ok} = run_delete(user, event, 1)
      assert_receive {:calendar_delete_result, _user_id, ^token, :deleted}
    end

    test "not found purges the cached row, so the event does not come back", %{
      user: user,
      caldav: caldav,
      event: event
    } do
      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :not_found}
      end)

      {token, :ok} = run_delete(user, event, 1)

      assert_receive {:calendar_delete_result, _user_id, ^token, :deleted}

      assert ProviderCalendarEventQueries.get_by_uid(caldav.id, "dentist-1") ==
               {:error, :not_found}
    end

    test "not found on a series delete purges the series' rows", %{user: user} do
      clicked = google_occurrence(user)
      sibling = google_occurrence(user, "20260608T090000Z")

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :not_found}
      end)

      {token, :ok} = run_delete(user, clicked, 1, scope: :series)

      assert_receive {:calendar_delete_result, _user_id, ^token, :deleted}

      for row <- [clicked, sibling] do
        assert ProviderCalendarEventQueries.get_by_uid(row.calendar_integration_id, row.uid) ==
                 {:error, :not_found}
      end
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
      assert Changes.delete_notice(user.id, event) == :silent
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

      assert Changes.delete_notice(user.id, event) == {:notifies, {:attendees, 2}}
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

      assert Changes.delete_notice(user.id, event) == {:notifies, :booking}
    end

    for status <- ["cancelled", "expired"] do
      test "the copy of a #{status} meeting deletes like a plain event", %{
        user: user,
        caldav: caldav,
        event: event
      } do
        insert(:meeting,
          organizer_user: user,
          organizer_user_id: user.id,
          calendar_integration_id: caldav.id,
          calendar_uid: event.uid,
          status: unquote(status)
        )

        assert Changes.delete_notice(user.id, event) == :silent
      end
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

      assert Changes.delete_notice(user.id, event) == {:notifies, :booking}
    end
  end
end
