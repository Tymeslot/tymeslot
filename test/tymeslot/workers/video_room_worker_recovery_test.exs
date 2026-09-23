defmodule Tymeslot.Workers.VideoRoomWorkerRecoveryTest do
  # The long-term recovery path: what the worker does once its ordinary retries
  # are spent and the provider is still down. The first-attempt and success
  # cases live in `VideoRoomWorkerTest`.
  use Tymeslot.DataCase, async: false

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Oban.Job
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Webhooks
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoRoom.Recovery
  alias Tymeslot.Workers.VideoRoomWorker
  alias Tymeslot.Workers.WebhookWorker

  setup :verify_on_exit!

  describe "perform/1 - recovery once ordinary retries are spent" do
    test "sends fallback emails on final failure and enters long-term recovery with distributed snooze" do
      %{meeting: meeting, meeting_type: _meeting_type} = setup_future_meeting_scenario()

      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:error, %Mint.TransportError{reason: :econnrefused}}
      end)

      # Meeting is 3 days away, but earliest reminder is 24h before.
      # Deadline = 3 days - 24h = 2 days away.
      assert {:ok, expected_snooze_first} =
               Recovery.snooze_seconds(meeting, 1, 5)

      assert {:snooze, snooze_first} =
               perform_job(
                 VideoRoomWorker,
                 %{
                   "meeting_id" => meeting.id,
                   "announce" => true
                 },
                 attempt: 5
               )

      assert_in_delta(snooze_first, expected_snooze_first, 2)

      email_jobs_after_first = all_enqueued(worker: EmailWorker)
      assert email_jobs_after_first != []

      # Now test a meeting where the reminder deadline is very close (e.g., in 4 hours)
      # 24h reminder + 4h from now = 28h from now
      closer_start = DateTime.add(DateTime.utc_now(), 28 * 3600, :second)
      closer_end = DateTime.add(closer_start, 3600, :second)

      {:ok, meeting} =
        MeetingQueries.update_meeting(meeting, %{
          start_time: closer_start,
          end_time: closer_end
        })

      # Deadline is 4h away. Cutoff buffer is 5m.
      assert {:ok, expected_snooze_second} =
               Recovery.snooze_seconds(meeting, 2, 5)

      assert {:snooze, snooze_second} =
               perform_job(
                 VideoRoomWorker,
                 %{
                   "meeting_id" => meeting.id,
                   "announce" => true
                 },
                 attempt: 6
               )

      assert_in_delta(snooze_second, expected_snooze_second, 2)

      email_jobs_after_second = all_enqueued(worker: EmailWorker)
      assert length(email_jobs_after_second) == length(email_jobs_after_first)
    end

    test "exhausts recovery even when snoozes no longer advance the job's attempt" do
      %{meeting: meeting} = setup_future_meeting_scenario()

      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:error, %Mint.TransportError{reason: :econnrefused}}
      end)

      args = %{"meeting_id" => meeting.id, "announce" => true}

      # Recovery advances purely by snoozing, and from Oban 2.24 a snooze rolls
      # `attempt` back and records itself in `meta["snoozed"]` instead. A loop
      # counting attempts alone would therefore sit on attempt 5 for as long as
      # the deadline allowed, retrying a meeting booked far in advance far more
      # than the five times it is budgeted.
      for snoozed <- 0..4 do
        assert {:snooze, _seconds} =
                 perform_job(VideoRoomWorker, args, attempt: 5, meta: %{"snoozed" => snoozed})
      end

      assert {:discard, "Recovery attempts exhausted"} =
               perform_job(VideoRoomWorker, args, attempt: 5, meta: %{"snoozed" => 5})
    end

    test "discards recovery when reminder deadline already passed" do
      %{meeting: meeting, meeting_type: _meeting_type} = setup_future_meeting_scenario()

      # Meeting is in 2 hours, but reminder is 24 hours before (deadline passed)
      soon_start = DateTime.add(DateTime.utc_now(), 2 * 3600, :second)
      soon_end = DateTime.add(soon_start, 3600, :second)

      {:ok, meeting} =
        MeetingQueries.update_meeting(meeting, %{
          start_time: soon_start,
          end_time: soon_end
        })

      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:error, %Mint.TransportError{reason: :econnrefused}}
      end)

      assert {:discard, "Recovery deadline passed"} =
               perform_job(
                 VideoRoomWorker,
                 %{
                   "meeting_id" => meeting.id,
                   "announce" => true
                 },
                 attempt: 5
               )
    end

    test "discards on final failure if meeting already started" do
      %{meeting: meeting} = setup_video_scenario()

      # Ensure meeting is in the past
      meeting = Repo.get!(MeetingSchema, meeting.id)
      past_start = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, meeting} =
        MeetingQueries.update_meeting(meeting, %{start_time: past_start})

      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:error, %Mint.TransportError{reason: :econnrefused}}
      end)

      # Should NOT snooze if meeting already started
      assert {:discard, "Meeting already started"} =
               perform_job(
                 VideoRoomWorker,
                 %{
                   "meeting_id" => meeting.id,
                   "announce" => true
                 },
                 attempt: 5
               )
    end

    test "a room arriving after recovery announced the booking does not announce it twice" do
      %{meeting: meeting} = setup_future_meeting_scenario()

      {:ok, _webhook} =
        Webhooks.create_webhook(meeting.organizer_user_id, %{
          name: "Late room",
          url: "https://example.com/hooks/late-room",
          events: ["meeting.created"]
        })

      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:error, %Mint.TransportError{reason: :econnrefused}}
      end)

      # Ordinary retries are spent, so recovery announces the booking without a
      # join link rather than leave the attendees waiting on one.
      assert {:snooze, _seconds} =
               perform_job(
                 VideoRoomWorker,
                 %{"meeting_id" => meeting.id, "announce" => true},
                 attempt: 5
               )

      assert_enqueued(worker: WebhookWorker)

      # Recovery snoozes for hours, and every channel's Oban uniqueness window
      # is five minutes wide, so by the time the next attempt runs none of them
      # would suppress a repeat. Clearing the queue is what makes a second
      # fan-out visible here rather than silently deduped.
      Repo.delete_all(Job)

      # The provider comes back and a later recovery attempt gets its room. The
      # link is worth having, the second `meeting.created` is not: the
      # subscriber would see the same booking arrive twice.
      expect_mirotalk_success()

      assert :ok =
               perform_job(
                 VideoRoomWorker,
                 %{"meeting_id" => meeting.id, "announce" => true},
                 attempt: 6
               )

      refute_enqueued(worker: WebhookWorker)
      refute_enqueued(worker: EmailWorker)
    end
  end

  defp setup_future_meeting_scenario do
    %{meeting: meeting} = setup_video_scenario()

    # Create a meeting type with a 24-hour reminder
    user = Repo.get!(Tymeslot.Auth.UserSchema, meeting.organizer_user_id)

    meeting_type =
      insert(:meeting_type, user: user, reminder_config: [%{value: 24, unit: "hours"}])

    # Ensure meeting is far in the future (e.g., 3 days)
    meeting = Repo.get!(MeetingSchema, meeting.id)
    # 3 days
    future_start = DateTime.add(DateTime.utc_now(), 259_200, :second)
    future_end = DateTime.add(future_start, 3600, :second)

    {:ok, meeting} =
      MeetingQueries.update_meeting(meeting, %{
        start_time: future_start,
        end_time: future_end,
        meeting_type_id: meeting_type.id
      })

    %{meeting: meeting, meeting_type: meeting_type}
  end
end
