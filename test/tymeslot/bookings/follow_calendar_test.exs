defmodule Tymeslot.Bookings.FollowCalendarTest do
  @moduledoc """
  `FollowCalendar.execute/4` against the real email service: a host moved a
  booked meeting in their own calendar, and the booking follows that time.

  The move must do everything a reschedule does afterwards (emails, reminders,
  webhooks, video room) and nothing that chooses or writes the time: the
  calendar already holds it.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Bookings.FollowCalendar
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoRoomWorker
  alias Tymeslot.Workers.VideoSyncWorker
  alias Tymeslot.Workers.WebhookWorker

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      telegram_notifications_allowed: true,
      telegram_shared_bot: false
    )

    TestMocks.setup_email_mocks()

    # The real service, so the templates actually render. Restored afterwards
    # for the rest of the suite.
    original_service = Application.get_env(:tymeslot, :email_service_module)
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)

    # `Delivery.deliver/1` runs inside the circuit-breaker GenServer, so
    # Swoosh's test adapter would otherwise post `{:email, _}` to that process
    # rather than to this one. Pointing the adapter at this test collects the
    # rendered emails here instead. Safe because the module is `async: false`:
    # no other test runs while these do.
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, original_service)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    user = insert(:user)
    insert(:profile, user: user, timezone: "Europe/Berlin")

    insert(:webhook, user: user, events: ["meeting.rescheduled"])
    insert(:telegram_integration, user: user, events: ["meeting.rescheduled"])

    %{user: user}
  end

  describe "execute/4" do
    test "moves the meeting and follows a changed length", %{user: user} do
      meeting = insert_future_meeting(user)
      {new_start, new_end} = new_times(meeting)

      assert {:ok, updated} = FollowCalendar.execute(meeting, new_start, new_end)

      assert updated.start_time == new_start
      assert updated.end_time == new_end
      assert updated.duration == 45
      assert Repo.get!(MeetingSchema, meeting.id).duration == 45
    end

    test "advances ical_sequence and clears the external-change flag", %{user: user} do
      meeting = insert_future_meeting(user, calendar_sync_status: "externally_modified")
      {new_start, new_end} = new_times(meeting)

      assert {:ok, updated} = FollowCalendar.execute(meeting, new_start, new_end)

      assert updated.ical_sequence == meeting.ical_sequence + 1
      assert updated.calendar_sync_status == nil
    end

    test "records the event's end as the one a later end change is measured against",
         %{user: user} do
      meeting = insert_future_meeting(user, seen_calendar_end_time: nil)
      {new_start, new_end} = new_times(meeting)

      assert {:ok, _updated} = FollowCalendar.execute(meeting, new_start, new_end)

      assert Repo.get!(MeetingSchema, meeting.id).seen_calendar_end_time == new_end
    end

    test "writes nothing to the calendar", %{user: user} do
      meeting = insert_future_meeting(user)
      {new_start, new_end} = new_times(meeting)

      assert {:ok, _updated} = FollowCalendar.execute(meeting, new_start, new_end)

      refute_enqueued(worker: CalendarEventWorker)
    end

    test "a guard refusing the locked row writes and sends nothing", %{user: user} do
      stale = insert_future_meeting(user, calendar_sync_status: "externally_modified")
      {new_start, new_end} = new_times(stale)

      # A confirm from another tab moved the booking after `stale` was read,
      # clearing the flag; only the locked row knows.
      stale
      |> Changeset.change(calendar_sync_status: nil)
      |> Repo.update!()

      still_flagged = fn
        %{calendar_sync_status: "externally_modified"} -> :ok
        _current -> {:error, :not_flagged}
      end

      assert {:error, :not_flagged} =
               FollowCalendar.execute(stale, new_start, new_end, guard: still_flagged)

      reloaded = Repo.get!(MeetingSchema, stale.id)
      assert reloaded.start_time == stale.start_time
      assert reloaded.ical_sequence == stale.ical_sequence
      refute_enqueued(worker: EmailWorker, args: %{"action" => "send_reschedule_emails"})
      refute_enqueued(worker: VideoSyncWorker)
    end

    test "re-pins the reminders to the new time", %{user: user} do
      reminder = %{"value" => 24, "unit" => "hours"}
      meeting = insert_future_meeting(user, reminders: [reminder], reminders_sent: [reminder])
      {new_start, new_end} = new_times(meeting)

      # The reminder pinned to the old time, still waiting to send.
      old_reminder_at = DateTime.add(meeting.start_time, -24, :hour)
      :ok = EmailScheduler.schedule_reminder_emails(meeting.id, 24, "hours", old_reminder_at)
      assert [old_job] = all_enqueued(worker: EmailWorker)
      assert DateTime.compare(old_job.scheduled_at, old_reminder_at) == :eq

      assert {:ok, updated} = FollowCalendar.execute(meeting, new_start, new_end)

      assert updated.reminders_sent == []

      jobs = all_enqueued(worker: EmailWorker, args: %{"action" => "send_reminder_emails"})
      assert jobs != []
      refute Enum.any?(jobs, &(&1.id == old_job.id))

      for job <- jobs do
        assert DateTime.compare(job.scheduled_at, new_start) == :lt
        assert DateTime.compare(job.scheduled_at, meeting.start_time) == :gt
      end
    end

    test "emails the attendee and the organiser", %{user: user} do
      meeting = insert_future_meeting(user)
      {new_start, new_end} = new_times(meeting)

      assert {:ok, _updated} = FollowCalendar.execute(meeting, new_start, new_end)

      delivered = delivered_emails()

      assert delivered[meeting.attendee_email].subject =~ "Rescheduled"
      assert delivered[meeting.organizer_email].subject =~ "Rescheduled"
    end

    test "tells the host they moved the meeting, not the attendee", %{user: user} do
      meeting = insert_future_meeting(user, attendee_name: "Ada Attendee")
      {new_start, new_end} = new_times(meeting)

      assert {:ok, _updated} = FollowCalendar.execute(meeting, new_start, new_end)

      delivered = delivered_emails()
      organizer = delivered[meeting.organizer_email]
      attendee = delivered[meeting.attendee_email]

      for body <- [organizer.text_body, organizer.html_body] do
        assert body =~ "You moved this meeting in your calendar."
        refute body =~ "has moved your meeting"
      end

      refute attendee.text_body =~ "You moved this meeting in your calendar."
    end

    test "still tells the host they moved it when the meeting's room comes later",
         %{user: user} do
      integration = insert(:video_integration, user: user, provider: "mirotalk")

      meeting =
        insert_future_meeting(user,
          attendee_name: "Ada Attendee",
          video_integration_id: integration.id,
          video_room_id: nil
        )

      {new_start, new_end} = new_times(meeting)

      assert {:ok, _updated} = FollowCalendar.execute(meeting, new_start, new_end)

      # The room's job owns the announcement, so nothing is sent until it runs.
      refute_enqueued(worker: EmailWorker, args: %{"action" => "send_reschedule_emails"})

      [job] = all_enqueued(worker: VideoRoomWorker, args: %{"meeting_id" => meeting.id})
      expect_mirotalk_success()
      assert :ok = perform_job(VideoRoomWorker, job.args)

      organizer = delivered_emails()[meeting.organizer_email]

      for body <- [organizer.text_body, organizer.html_body] do
        assert body =~ "You moved this meeting in your calendar."
        refute body =~ "has moved your meeting"
      end
    end

    test "resets and emails the booking's guests", %{user: user} do
      meeting = insert_future_meeting(user)
      {new_start, new_end} = new_times(meeting)

      {:ok, guest} =
        GuestQueries.insert_guest(%{meeting_id: meeting.id, email: "guest@example.com"})

      {:ok, _rsvp} = GuestQueries.update_rsvp(guest, %{status: "accepted"})

      assert {:ok, _updated} = FollowCalendar.execute(meeting, new_start, new_end)

      assert [%{status: "pending"}] = GuestQueries.list_for_meeting(meeting.id)
      send_reschedule_emails()
      assert_received {:email, %{to: [{_name, "guest@example.com"}]}}
    end

    test "dispatches meeting.rescheduled", %{user: user} do
      meeting = insert_future_meeting(user)
      {new_start, new_end} = new_times(meeting)

      assert {:ok, _updated} = FollowCalendar.execute(meeting, new_start, new_end)

      assert all_enqueued(worker: WebhookWorker) != []
    end

    test "moves a separate video room", %{user: user} do
      meeting = insert_future_meeting(user, video_room_id: "room-1")
      {new_start, new_end} = new_times(meeting)

      assert {:ok, _updated} = FollowCalendar.execute(meeting, new_start, new_end)

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"meeting_id" => meeting.id, "action" => "update"}
      )
    end
  end

  # ----- helpers -----

  defp new_times(meeting) do
    new_start = DateTime.add(meeting.start_time, 2, :day)
    {new_start, DateTime.add(new_start, 45, :minute)}
  end

  # Every email the move sends, keyed by recipient address. The notices go
  # out from the reschedule email job, which is run here.
  defp delivered_emails do
    send_reschedule_emails()
    assert_received {:email, first}
    assert_received {:email, second}

    Map.new([first, second], fn email ->
      {email.to |> hd() |> elem(1), email}
    end)
  end

  defp send_reschedule_emails do
    assert %{success: 1} =
             Oban.drain_queue(queue: :emails)
  end

  defp insert_future_meeting(user, attrs \\ []) do
    start_time = future_datetime(3, :day)

    insert(
      :meeting,
      Keyword.merge(
        [
          uid: UUID.generate(),
          organizer_user_id: user.id,
          organizer_email: "organiser-#{user.id}@example.com",
          start_time: start_time,
          end_time: DateTime.add(start_time, 30, :minute),
          duration: 30,
          status: "confirmed"
        ],
        attrs
      )
    )
  end

  defp future_datetime(amount, unit) do
    future = DateTime.add(DateTime.utc_now(), amount, unit)

    %{future | hour: 10, minute: 0, second: 0, microsecond: {0, 0}}
  end
end
