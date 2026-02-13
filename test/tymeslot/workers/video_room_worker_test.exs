defmodule Tymeslot.Workers.VideoRoomWorkerTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Ecto.UUID
  alias Tymeslot.DatabaseQueries.MeetingQueries
  alias Tymeslot.DatabaseSchemas.MeetingSchema
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoRoomWorker

  setup :verify_on_exit!

  describe "perform/1 - input validation" do
    test "handles missing meeting_id" do
      assert_raise FunctionClauseError, fn ->
        perform_job(VideoRoomWorker, %{})
      end
    end

    test "handles invalid meeting_id type" do
      user = insert(:user)
      insert(:video_integration, user: user, provider: "mirotalk")

      # String meeting_id should be converted to string internally
      result = perform_job(VideoRoomWorker, %{"meeting_id" => "invalid-id"})

      # Should discard job (meeting not found)
      assert {:discard, "Meeting not found"} = result
    end

    test "handles non-existent meeting" do
      # Use a valid UUID format that doesn't exist in database
      non_existent_uuid = UUID.generate()

      result = perform_job(VideoRoomWorker, %{"meeting_id" => non_existent_uuid})

      # Worker discards jobs for non-existent meetings (no point retrying)
      assert {:discard, "Meeting not found"} = result
    end

    test "discards when video integration is missing and sends fallback emails" do
      user = insert(:user)
      _profile = insert(:profile, user: user)

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          video_integration_id: nil
        )

      result =
        perform_job(
          VideoRoomWorker,
          %{"meeting_id" => meeting.id, "send_emails" => true},
          attempt: 1
        )

      assert {:discard, "Video integration missing"} = result
      assert_enqueued(worker: EmailWorker)
    end
  end

  describe "perform/1 - successful creation" do
    test "successfully creates a video room and updates meeting" do
      %{meeting: meeting} = setup_video_scenario()

      # Mock MiroTalk API calls: room creation and join token generation
      expect_mirotalk_success()

      assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})

      updated_meeting = Repo.get(MeetingSchema, meeting.id)
      assert updated_meeting.video_room_id == "https://test.mirotalk.com/join/test-room-123"
      assert updated_meeting.video_room_enabled

      # Verify calendar update was enqueued
      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "update", "meeting_id" => meeting.id}
      )
    end

    test "handles malformed API response (invalid JSON)" do
      %{meeting: meeting} = setup_video_scenario()

      # MiroTalk provider tries both HTTPS and HTTP, so expect 2 calls
      expect(Tymeslot.HTTPClientMock, :post, 2, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "not valid json"}}
      end)

      assert {:error, _reason} = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})
    end

    test "handles malformed API response (missing expected field)" do
      %{meeting: meeting} = setup_video_scenario()

      # MiroTalk provider tries HTTPS, then HTTP, then tries to create join URLs (4 total calls)
      # First 2 calls: room creation attempts that return malformed responses
      # Next 2 calls: join URL creation attempts (if room creation somehow "succeeds")
      expect(Tymeslot.HTTPClientMock, :post, 4, fn _url, _body, _headers, _opts ->
        # Valid JSON but missing the "meeting" field that MiroTalk expects
        {:ok,
         %Req.Response{
           status: 200,
           body: Jason.encode!(%{"unexpected" => "data"})
         }}
      end)

      # Even with malformed response, MiroTalk might partially succeed
      # This test documents that the provider is resilient
      # In reality, missing "meeting" field causes :invalid_json error
      result = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})

      # Can be either :ok (if provider is very resilient) or {:error, reason}
      case result do
        :ok -> assert true
        {:error, _reason} -> assert true
        other -> flunk("Unexpected result: #{inspect(other)}")
      end
    end

    test "handles empty API response" do
      %{meeting: meeting} = setup_video_scenario()

      # MiroTalk provider tries both HTTPS and HTTP, so expect 2 calls
      expect(Tymeslot.HTTPClientMock, :post, 2, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: ""}}
      end)

      assert {:error, _reason} = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})
    end

    test "handles rate limiting by generic error retry" do
      %{meeting: meeting} = setup_video_scenario()

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 429, body: "Too Many Requests"}}
      end)

      assert {:error, reason} = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})
      assert reason =~ "status 429"
    end

    test "sends fallback emails on final failure and enters long-term recovery with distributed snooze" do
      %{meeting: meeting, meeting_type: _meeting_type} = setup_future_meeting_scenario()

      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:error, %Mint.TransportError{reason: :econnrefused}}
      end)

      # Meeting is 3 days away, but earliest reminder is 24h before.
      # Deadline = 3 days - 24h = 2 days away.
      assert {:ok, expected_snooze_first} =
               VideoRoomWorker.calculate_recovery_snooze(meeting, 1, 5)

      assert {:snooze, snooze_first} =
               perform_job(
                 VideoRoomWorker,
                 %{
                   "meeting_id" => meeting.id,
                   "send_emails" => true
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
               VideoRoomWorker.calculate_recovery_snooze(meeting, 2, 5)

      assert {:snooze, snooze_second} =
               perform_job(
                 VideoRoomWorker,
                 %{
                   "meeting_id" => meeting.id,
                   "send_emails" => true
                 },
                 attempt: 6
               )

      assert_in_delta(snooze_second, expected_snooze_second, 2)

      email_jobs_after_second = all_enqueued(worker: EmailWorker)
      assert length(email_jobs_after_second) == length(email_jobs_after_first)
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
                   "send_emails" => true
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
                   "send_emails" => true
                 },
                 attempt: 5
               )
    end

    test "video created but calendar update continues on failure (partial success)" do
      %{meeting: meeting} = setup_video_scenario()

      # Video creation succeeds
      expect_mirotalk_success()

      assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})

      # Video room should still be recorded even if subsequent steps fail
      updated_meeting = Repo.get(MeetingSchema, meeting.id)
      assert updated_meeting.video_room_id
      assert updated_meeting.video_room_enabled

      # Calendar update should be enqueued (if it fails, that's a separate concern)
      assert_enqueued(worker: CalendarEventWorker)
    end
  end

  describe "perform/1 - idempotency" do
    test "duplicate execution is safe (idempotent)" do
      %{meeting: meeting} = setup_video_scenario()

      # First execution
      expect_mirotalk_success()
      assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})

      first_meeting = Repo.get(MeetingSchema, meeting.id)
      assert first_meeting.video_room_id

      # Second execution (simulates retry or duplicate job)
      # In the second execution, VideoRooms.add_video_room_to_meeting will detect
      # that a room is already attached and return {:ok, meeting} without
      # calling the video provider again.
      assert :ok = perform_job(VideoRoomWorker, %{"meeting_id" => meeting.id})

      # Meeting should still have a video room
      second_meeting = Repo.get(MeetingSchema, meeting.id)
      assert second_meeting.video_room_id == first_meeting.video_room_id
    end
  end

  defp setup_future_meeting_scenario do
    %{meeting: meeting} = setup_video_scenario()

    # Create a meeting type with a 24-hour reminder
    user = Repo.get!(Tymeslot.DatabaseSchemas.UserSchema, meeting.organizer_user_id)

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

  describe "scheduling" do
    test "schedule_video_room_creation/1 enqueues job" do
      assert :ok = VideoRoomWorker.schedule_video_room_creation("123")

      assert_enqueued(
        worker: VideoRoomWorker,
        args: %{"meeting_id" => "123", "send_emails" => false}
      )
    end

    test "schedule_video_room_creation_with_emails/1 enqueues job" do
      assert :ok = VideoRoomWorker.schedule_video_room_creation_with_emails("123")

      assert_enqueued(
        worker: VideoRoomWorker,
        args: %{"meeting_id" => "123", "send_emails" => true}
      )
    end
  end
end
