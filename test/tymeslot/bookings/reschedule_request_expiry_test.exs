defmodule Tymeslot.Bookings.RescheduleRequestExpiryTest do
  @moduledoc """
  A host's reschedule request that the attendee never answers lapses at the
  later of the meeting's original start and seven days after it was sent:
  the meeting expires, both sides are told, and neither side's links work
  any more. Before that it stays answerable, even past the original time.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory
  import Tymeslot.MeetingTestHelpers
  import Tymeslot.Test.ClockHelpers

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.Bookings.RescheduleRequest
  alias Tymeslot.Bookings.RescheduleRequestExpiry
  alias Tymeslot.Bookings.Workers.RescheduleRequestExpiryWorker
  alias Tymeslot.Bookings.Workers.RescheduleRequestSweepWorker
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoSyncWorker

  @day 86_400

  setup :verify_on_exit!

  setup do
    TestMocks.stub_no_calendar_events()

    # The real email service, so the rendered emails reach this process.
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    :ok
  end

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)

  defp drain_emails, do: Oban.drain_queue(queue: :emails, with_recursion: true)

  # Sends every email queued so far and forgets them, so a later assertion
  # sees only what the step under test sent.
  defp flush_emails do
    drain_emails()
    flush_mailbox()
  end

  defp flush_mailbox do
    receive do
      {:email, _email} -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp expiry_job(meeting) do
    [job] =
      all_enqueued(worker: RescheduleRequestExpiryWorker, args: %{"meeting_id" => meeting.id})

    job
  end

  defp requested!(meeting) do
    assert :ok = RescheduleRequest.send_reschedule_request(meeting)
    reload(meeting)
  end

  # A request already open when expiry was introduced: stamped, with no job.
  defp open_request(user, requested_ago, start_offset) do
    insert_meeting_for_user(user, %{
      start_offset: start_offset,
      reschedule_requested_at: DateTime.add(DateTime.utc_now(:second), -requested_ago, :second)
    })
  end

  defp new_time_params do
    %{
      date: Date.to_string(Date.add(Date.utc_today(), 2)),
      time: "2:00 PM",
      duration: "60min",
      user_timezone: "America/New_York"
    }
  end

  describe "a request the attendee never answers" do
    test "expires at its deadline, tells both sides, and closes both sides' links" do
      %{user: user} = create_user_with_profile(%{username: "lapsehost"})

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: 2 * @day,
          title: "Quarterly review",
          attendee_name: "Ada Attendee",
          attendee_email: "ada@example.com",
          organizer_name: "Hal Host",
          organizer_email: "hal@example.com",
          video_room_id: "room-1"
        })

      requested = requested!(meeting)
      flush_emails()

      job = expiry_job(requested)
      deadline = MeetingState.reschedule_request_deadline(requested)
      # Asked two days ahead, so the seven-day window outlasts the start.
      assert DateTime.compare(deadline, DateTime.add(requested.reschedule_requested_at, 7 * @day)) ==
               :eq

      assert DateTime.compare(job.scheduled_at, deadline) == :eq

      freeze_clock(deadline)
      assert :ok = perform_job(RescheduleRequestExpiryWorker, job.args)

      expired = reload(meeting)
      assert expired.status == :expired
      assert expired.reschedule_requested_at == requested.reschedule_requested_at
      assert MeetingState.visible_to_organiser?(expired)
      refute MeetingState.awaiting_new_time?(expired)

      # The calendar copy and the video room go, as for any ended meeting.
      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "delete", "meeting_id" => meeting.id}
      )

      assert_enqueued(worker: VideoSyncWorker, args: %{"meeting_id" => meeting.id})

      drain_emails()

      assert_received {:email, host_email}
      assert_received {:email, attendee_email}
      refute_received {:email, _third}

      [attendee_email, host_email] =
        Enum.sort_by([host_email, attendee_email], fn email -> email.to end)

      assert host_email.to == [{"Hal Host", "hal@example.com"}]
      assert host_email.subject =~ "No new time picked: Quarterly review"
      assert host_email.text_body =~ "Ada Attendee didn't pick a new time"

      assert attendee_email.to == [{"Ada Attendee", "ada@example.com"}]
      assert attendee_email.subject =~ "Reschedule request lapsed: Quarterly review"
      assert attendee_email.text_body =~ "/lapsehost"
      ics = Enum.find(attendee_email.attachments, &(&1.content_type == "text/calendar"))
      assert ics.data =~ "STATUS:CANCELLED"
      assert ics.data =~ "UID:#{meeting.calendar_uid}@"

      # Neither the attendee's link nor the host's cancel works any more.
      assert {:error, {:not_reschedulable, :request_lapsed}} =
               Policy.can_reschedule_meeting?(expired)

      assert {:error, {:not_cancellable, :request_lapsed}} = Policy.can_cancel_meeting?(expired)
    end

    test "is refused from its deadline even before the expiry job has run" do
      %{user: user} = create_user_with_profile()
      meeting = open_request(user, 7 * @day + 60, -@day)

      assert reload(meeting).status == :confirmed

      assert {:error, {:not_reschedulable, :request_lapsed}} =
               Policy.can_reschedule_meeting?(meeting)

      assert {:error, {:not_cancellable, :request_lapsed}} = Policy.can_cancel_meeting?(meeting)

      assert {:error, {:not_reschedulable, :request_lapsed}} =
               Reschedule.execute(meeting.uid, new_time_params(), user.id)
    end

    test "sent ten minutes before the meeting, stays answerable for seven days" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 600})

      requested = requested!(meeting)
      job = expiry_job(requested)
      deadline = DateTime.add(requested.reschedule_requested_at, 7 * @day)
      assert DateTime.compare(job.scheduled_at, deadline) == :eq

      # A day after the original time, the request is still open.
      freeze_clock(DateTime.add(requested.start_time, @day))
      assert :ok = Policy.can_reschedule_meeting?(requested)
      assert :ok = Policy.can_cancel_meeting?(requested)
      assert {:ok, %{expired: 0}} = perform_job(RescheduleRequestSweepWorker, %{})

      # One second before the deadline it still is; an early job waits.
      freeze_clock(DateTime.add(deadline, -1))
      assert :ok = Policy.can_reschedule_meeting?(requested)
      assert {:snooze, 1} = perform_job(RescheduleRequestExpiryWorker, job.args)
      assert reload(meeting).status == :confirmed

      freeze_clock(deadline)

      assert {:error, {:not_reschedulable, :request_lapsed}} =
               Policy.can_reschedule_meeting?(requested)

      assert :ok = perform_job(RescheduleRequestExpiryWorker, job.args)
      assert reload(meeting).status == :expired
    end
  end

  describe "a request answered before its deadline" do
    test "is left alone when its expiry job runs" do
      %{user: user} = create_always_bookable_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: @day})

      requested = requested!(meeting)
      job = expiry_job(requested)

      assert {:ok, _moved} = Reschedule.execute(meeting.uid, new_time_params(), user.id)
      flush_emails()

      freeze_clock(DateTime.add(requested.reschedule_requested_at, 8 * @day))

      assert {:discard, "Reschedule request no longer pending"} =
               perform_job(RescheduleRequestExpiryWorker, job.args)

      answered = reload(meeting)
      assert answered.status == :confirmed
      assert answered.reschedule_requested_at == nil
      drain_emails()
      refute_received {:email, _any}
    end

    test "a later request is not ended by an earlier request's job" do
      %{user: user} = create_always_bookable_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: @day})

      first = requested!(meeting)
      first_job = expiry_job(first)
      {:ok, _moved} = Reschedule.execute(meeting.uid, new_time_params(), user.id)

      freeze_clock(DateTime.add(first.reschedule_requested_at, 60))
      second = requested!(reload(meeting))

      freeze_clock(DateTime.add(first.reschedule_requested_at, 7 * @day + 30))

      assert {:discard, _no_longer_pending} =
               perform_job(RescheduleRequestExpiryWorker, first_job.args)

      assert reload(meeting).reschedule_requested_at == second.reschedule_requested_at
      assert reload(meeting).status == :confirmed
    end
  end

  describe "an answer racing the expiry" do
    test "the attendee's answer committed first leaves the expiry nothing to do" do
      %{user: user} = create_always_bookable_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: @day})

      # The sweep's copy, read before the attendee picked a time.
      stale = requested!(meeting)

      assert {:ok, _moved} = Reschedule.execute(meeting.uid, new_time_params(), user.id)
      flush_emails()

      freeze_clock(DateTime.add(stale.reschedule_requested_at, 8 * @day))
      assert {:error, :not_lapsed} = RescheduleRequestExpiry.expire(stale)

      assert reload(meeting).status == :confirmed
      refute_enqueued(worker: EmailWorker, args: %{"action" => "send_reschedule_request_lapsed"})
    end

    test "the expiry committed first refuses the attendee's answer under the row lock" do
      %{user: user} = create_always_bookable_profile()

      # The attendee's copy, read while the request was still open.
      stale = open_request(user, 7 * @day + 60, -@day)

      assert {:ok, _expired} = RescheduleRequestExpiry.expire(stale)

      start = DateTime.add(DateTime.utc_now(:second), 2 * @day)

      new_times = %{
        start_time: start,
        end_time: DateTime.add(start, 3_600),
        duration_minutes: 60
      }

      assert {:error, {:not_reschedulable, :request_lapsed}} =
               Reschedule.apply_new_time(stale, new_times, nil, %{})

      assert reload(stale).status == :expired
      assert DateTime.compare(reload(stale).start_time, stale.start_time) == :eq
    end
  end

  describe "requests already open without a job" do
    test "are expired by the sweep once due, and only once" do
      %{user: user} = create_user_with_profile()
      due = open_request(user, 7 * @day + 60, -@day)
      # Past its original time but inside its seven days.
      not_due = open_request(user, 2 * @day, -@day)
      # Asked long ago for a meeting still ahead: its start is the deadline.
      ahead = open_request(user, 9 * @day, @day)

      assert {:ok, %{expired: 1, failed: 0}} = perform_job(RescheduleRequestSweepWorker, %{})

      assert reload(due).status == :expired
      assert reload(not_due).status == :confirmed
      assert reload(ahead).status == :confirmed

      drain_emails()
      assert_received {:email, _host}
      assert_received {:email, _attendee}

      assert {:ok, %{expired: 0}} = perform_job(RescheduleRequestSweepWorker, %{})
      assert {:error, :not_lapsed} = RescheduleRequestExpiry.expire(due)
      drain_emails()
      refute_received {:email, _again}
    end

    test "are dated to their deadline, however late the sweep reaches them" do
      %{user: user} = create_user_with_profile()
      # Asked a month before a meeting that started a hundred days ago: the
      # start is the deadline.
      by_start = open_request(user, 130 * @day, -100 * @day)
      # Asked the day before a meeting two months ago: the seven days are.
      by_window = open_request(user, 60 * @day, -59 * @day)

      assert {:ok, %{expired: 2}} = perform_job(RescheduleRequestSweepWorker, %{})

      for meeting <- [by_start, by_window] do
        expired = reload(meeting)
        assert expired.status == :expired

        assert DateTime.compare(
                 expired.cancelled_at,
                 MeetingState.reschedule_request_deadline(meeting)
               ) == :eq
      end

      assert DateTime.compare(reload(by_start).cancelled_at, by_start.start_time) == :eq

      # Neither side is told months later: the news stopped mattering a week
      # after each deadline.
      drain_emails()
      refute_received {:email, _late}
    end
  end

  describe "a group meeting's request" do
    test "tells every participant still on it" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          start_offset: -@day,
          capacity: 5,
          attendee_name: nil,
          attendee_email: nil,
          reschedule_requested_at: DateTime.add(DateTime.utc_now(:second), -8 * @day)
        })

      insert(:participant, meeting: meeting, name: "Pat One", email: "one@example.com")
      insert(:participant, meeting: meeting, name: "Pat Two", email: "two@example.com")

      assert {:ok, _expired} = RescheduleRequestExpiry.expire(meeting)
      drain_emails()

      recipients =
        for _n <- 1..3 do
          assert_received {:email, email}
          email.to
        end

      assert [{"Pat One", "one@example.com"}] in recipients
      assert [{"Pat Two", "two@example.com"}] in recipients
      refute_received {:email, _fourth}

      assert {:error, {:not_reschedulable, :request_lapsed}} =
               Policy.can_reschedule_meeting?(reload(meeting))
    end
  end

  test "a meeting with no request has nothing to expire or schedule" do
    %{user: user} = create_user_with_profile()
    meeting = insert_meeting_for_user(user, %{start_offset: -@day})

    assert {:error, :not_lapsed} = RescheduleRequestExpiry.expire(meeting)
    assert :ok = RescheduleRequestExpiry.schedule(meeting)
    refute_enqueued(worker: RescheduleRequestExpiryWorker)
    assert {:ok, %{expired: 0}} = perform_job(RescheduleRequestSweepWorker, %{})
    assert {:ok, _same} = MeetingQueries.get_meeting(meeting.id)
  end
end
