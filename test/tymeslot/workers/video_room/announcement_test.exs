defmodule Tymeslot.Workers.VideoRoom.AnnouncementTest do
  @moduledoc """
  A reschedule's announcement, held by `Tymeslot.Workers.VideoRoomWorker`
  until the room it moved the meeting onto exists.

  Every test schedules the job the way a reschedule does and runs the args it
  enqueued, so the encoding is exercised as well as the delivery.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :video

  import Mox
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.{MeetingQueries, MeetingSchema}
  alias Tymeslot.Webhooks
  alias Tymeslot.Workers.VideoRoom.Announcement
  alias Tymeslot.Workers.{VideoRoomWorker, WebhookWorker}

  setup :verify_on_exit!

  describe "a reschedule held for its room" do
    setup do
      scenario = setup_video_scenario()

      {:ok, _webhook} =
        Webhooks.create_webhook(scenario.user.id, %{
          name: "Reschedules",
          url: "https://example.com/hooks/reschedules",
          events: ["meeting.rescheduled"]
        })

      test_pid = self()

      stub(EmailServiceMock, :send_reschedule_emails, fn details ->
        send(test_pid, {:reschedule_emails, details})
        {{:ok, :sent}, {:ok, :sent}}
      end)

      Map.put(scenario, :original, moved_back(scenario.meeting))
    end

    test "is announced with the join link once the room exists",
         %{meeting: meeting, original: original} do
      args = schedule_reschedule(meeting, original)
      expect_mirotalk_success()

      assert :ok = perform_job(VideoRoomWorker, args)

      assert_received {:reschedule_emails, details}
      assert details.attendee_video_url =~ "https://test.mirotalk.com/join/test-room-123"
      assert details.original_start_time == original.start_time
      assert_enqueued(worker: WebhookWorker, args: %{"event_type" => "meeting.rescheduled"})
    end

    test "is announced without a link when the room can never be created", %{user: user} do
      start_time = DateTime.utc_now() |> DateTime.add(3, :day) |> DateTime.truncate(:second)

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          video_integration_id: nil,
          start_time: start_time,
          end_time: DateTime.add(start_time, 30, :minute)
        )

      assert {:discard, "Video integration missing"} =
               perform_job(
                 VideoRoomWorker,
                 schedule_reschedule(meeting, moved_back(meeting)),
                 attempt: 1
               )

      assert_received {:reschedule_emails, %{attendee_video_url: nil}}
      assert_enqueued(worker: WebhookWorker, args: %{"event_type" => "meeting.rescheduled"})
    end

    test "is left to a later reschedule of the same meeting",
         %{meeting: meeting, original: original} do
      args = schedule_reschedule(meeting, original)

      # Moved again before the room was created: that reschedule told the
      # attendees about the meeting as it now is, and this job's email would
      # announce a move to a time the meeting no longer has.
      {:ok, _moved} =
        MeetingQueries.update_meeting(meeting, %{
          start_time: DateTime.add(meeting.start_time, 2, :hour),
          end_time: DateTime.add(meeting.end_time, 2, :hour)
        })

      expect_mirotalk_success()

      assert :ok = perform_job(VideoRoomWorker, args)

      refute_received {:reschedule_emails, _details}
      refute_enqueued(worker: WebhookWorker)
      assert Repo.get!(MeetingSchema, meeting.id).video_room_id
    end

    test "is not announced again by a room arriving after recovery announced it",
         %{meeting: meeting, original: original} do
      args = schedule_reschedule(meeting, original)

      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:error, %Mint.TransportError{reason: :econnrefused}}
      end)

      assert {:snooze, _seconds} = perform_job(VideoRoomWorker, args, attempt: 5)
      assert_received {:reschedule_emails, %{attendee_video_url: nil}}

      expect_mirotalk_success()

      assert :ok = perform_job(VideoRoomWorker, args, attempt: 6)

      # The link reaches the attendee through the meeting page and reminders;
      # a second email and event for the same move would not help.
      refute_received {:reschedule_emails, _details}
      assert Repo.get!(MeetingSchema, meeting.id).video_room_id
    end

    test "does not spend the booking's once-only confirmation",
         %{meeting: meeting, original: original} do
      expect_mirotalk_success()

      assert :ok = perform_job(VideoRoomWorker, schedule_reschedule(meeting, original))

      assert Repo.get!(MeetingSchema, meeting.id).announced_at == nil
    end
  end

  describe "scheduling" do
    test "each reschedule of a meeting gets its own announcing job" do
      meeting = insert(:meeting)
      first_move = %{meeting | start_time: DateTime.add(meeting.start_time, 1, :day)}
      second_move = %{first_move | start_time: DateTime.add(first_move.start_time, 1, :day)}

      schedule = &VideoRoomWorker.schedule_video_room_creation_with_reschedule_announcement/2

      assert :ok = schedule.(first_move, meeting)
      assert :ok = schedule.(first_move, meeting)
      assert :ok = schedule.(second_move, first_move)

      # The repeat of the first move is the same announcement and collapses
      # into its job. The second move is a different one, and the uniqueness
      # window includes completed jobs, so deduplicating it against the first
      # would leave the attendees never told of it.
      assert [_first, _second] = all_enqueued(worker: VideoRoomWorker)

      assert_enqueued(
        worker: VideoRoomWorker,
        args: %{
          "meeting_id" => meeting.id,
          "announce" => "rescheduled",
          "previous_start_time" => DateTime.to_iso8601(first_move.start_time),
          "start_time" => DateTime.to_iso8601(second_move.start_time)
        }
      )
    end

    test "a reschedule's args read back as the announcement they encode" do
      meeting = insert(:meeting)
      moved = %{meeting | start_time: DateTime.add(meeting.start_time, 1, :day)}

      decoded =
        moved
        |> Announcement.rescheduled(meeting)
        |> Announcement.to_args()
        |> Jason.encode!()
        |> Jason.decode!()
        |> Announcement.from_args()

      assert {:rescheduled, %{start_time: previous_start, end_time: previous_end}, to} = decoded
      assert previous_start == meeting.start_time
      assert previous_end == meeting.end_time
      assert to == moved.start_time
    end
  end

  defp moved_back(meeting),
    do: %{meeting | start_time: DateTime.add(meeting.start_time, -1, :day)}

  defp schedule_reschedule(meeting, original) do
    assert :ok =
             VideoRoomWorker.schedule_video_room_creation_with_reschedule_announcement(
               meeting,
               original
             )

    [job] = all_enqueued(worker: VideoRoomWorker, args: %{"meeting_id" => meeting.id})
    job.args
  end
end
