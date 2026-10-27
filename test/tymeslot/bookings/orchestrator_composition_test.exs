defmodule Tymeslot.Bookings.OrchestratorCompositionTest do
  @moduledoc """
  Composition tests for `Tymeslot.Bookings.Orchestrator`.

  `orchestrator_idor_test.exs` already locks in the organiser-scoping
  contract on the reschedule path; this module covers the remaining
  wrapper behaviour:

    * happy-path `submit_booking/2` delegates to `Create.execute/2` and
      yields a persisted meeting,
    * the rescheduling branch (`is_rescheduling: true`) delegates to
      `Reschedule.execute/4` and enqueues the expected CalendarEvent /
      webhook / Telegram jobs,
    * `get_meeting_for_reschedule/2` rejects meetings that policy
      disallows even for the correct organiser.

  Taken together with `confirmation_emails_integration_test.exs` (which
  covers `Create.execute/2` end-to-end), the wrapper is no longer a
  coverage blind spot.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :integration

  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoRoomWorker

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      telegram_notifications_allowed: true,
      telegram_shared_bot: false
    )

    TestMocks.setup_calendar_mocks()
    TestMocks.setup_email_mocks()

    Mox.stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    user = insert(:user, email: "organiser@example.com", name: "Organiser")
    profile = insert(:profile, user: user, timezone: "Europe/Berlin")
    # Booking composition is the subject here, so the host offers every hour
    # of every day and the schedule never refuses the bookings these tests make.
    schedule = open_schedule_for(profile)

    meeting_type =
      insert(:meeting_type, user: user, name: "Intro", duration_minutes: 30, is_active: true)

    %{user: user, profile: profile, schedule: schedule, meeting_type: meeting_type}
  end

  describe "submit_booking/2 — new booking" do
    test "destructures the wrapper params and persists a confirmed meeting", %{
      user: user,
      meeting_type: meeting_type
    } do
      params = %{
        form_data: %{
          "name" => "Attendee",
          "email" => "attendee@example.com",
          "message" => ""
        },
        meeting_params: %{
          date: Date.add(Date.utc_today(), 1),
          time: "14:00",
          duration: "30min",
          user_timezone: "Europe/Berlin",
          organizer_user_id: user.id,
          meeting_type_id: meeting_type.id
        }
      }

      assert {:ok, meeting} = Orchestrator.submit_booking(params)
      assert meeting.status == "confirmed"
      assert meeting.attendee_email == "attendee@example.com"

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_confirmation_emails", "meeting_id" => meeting.id}
      )
    end
  end

  describe "submit_booking/2 — a refused booking time" do
    test "passes the refusal through as the booking rules gave it", %{
      user: user,
      schedule: schedule,
      meeting_type: meeting_type
    } do
      Repo.update!(Changeset.change(schedule, advance_booking_days: 30))

      params = %{
        form_data: %{"name" => "Attendee", "email" => "attendee@example.com", "message" => ""},
        meeting_params: %{
          date: Date.add(Date.utc_today(), 800),
          time: "14:00",
          duration: "30min",
          user_timezone: "Europe/Berlin",
          organizer_user_id: user.id,
          meeting_type_id: meeting_type.id
        }
      }

      assert {:error, {:too_far_ahead, 30}} = Orchestrator.submit_booking(params)
      assert Repo.aggregate(MeetingSchema, :count) == 0
    end
  end

  describe "submit_booking/2 — new booking with video room" do
    test "routes through the video-room branch and enqueues VideoRoomWorker", %{user: user} do
      video_integration = insert(:video_integration, user: user, provider: "mirotalk")

      # The chosen location is what decides a room gets created, so the type
      # has to offer one; `meeting_type` from setup is in-person only.
      video_type =
        insert(:meeting_type,
          user: user,
          name: "Video Call",
          locations: [video_location(video_integration)]
        )

      params = %{
        form_data: %{
          "name" => "Attendee",
          "email" => "attendee@example.com",
          "message" => ""
        },
        meeting_params: %{
          date: Date.add(Date.utc_today(), 1),
          time: "15:00",
          duration: "30min",
          user_timezone: "Europe/Berlin",
          organizer_user_id: user.id,
          meeting_type_id: video_type.id,
          with_video_room: true
        }
      }

      assert {:ok, meeting} = Orchestrator.submit_booking(params)
      assert meeting.status == "confirmed"

      assert_enqueued(
        worker: VideoRoomWorker,
        args: %{"meeting_id" => meeting.id, "announce" => true}
      )
    end
  end

  # The booking page always submits with `with_video_room: true`, so these go
  # through the exact path a visitor's submit takes.
  describe "submit_booking/2 — the fresh calendar read" do
    test "one submit reads the host's calendars exactly once", %{
      user: user,
      meeting_type: meeting_type
    } do
      count_fresh_fetches(fn -> {:ok, []} end)

      assert {:ok, %{status: "confirmed"}} =
               Orchestrator.submit_booking(video_submit(user, meeting_type))

      assert_received {:fresh_fetch, _user_id}
      refute_received {:fresh_fetch, _user_id}
    end

    test "an inactive meeting type is refused without reading the calendars", %{user: user} do
      inactive = insert(:meeting_type, user: user, duration_minutes: 30, is_active: false)

      count_fresh_fetches(fn -> {:ok, []} end)

      assert {:error, :meeting_type_inactive} =
               Orchestrator.submit_booking(video_submit(user, inactive))

      refute_received {:fresh_fetch, _user_id}
    end

    @tag :capture_log
    test "a calendar adapter that raises refuses the booking instead of crashing the caller",
         %{user: user, meeting_type: meeting_type} do
      count_fresh_fetches(fn -> raise "provider adapter blew up" end)

      # Unverifiable, not taken: the booker is told to try again later.
      assert {:error, :availability_unverifiable} =
               Orchestrator.submit_booking(video_submit(user, meeting_type))

      assert_received {:fresh_fetch, _user_id}
      assert Repo.aggregate(MeetingSchema, :count) == 0
    end
  end

  describe "submit_booking/2 — reschedule" do
    test "delegates to the reschedule path when is_rescheduling: true", %{
      user: user,
      meeting_type: meeting_type
    } do
      original = insert_future_meeting(user, meeting_type)

      # This profile has no explicit schedule, so `Bookings.ScheduleCheck` falls
      # back to the hard-coded business hours (11:00-19:30, Mon-Fri); the target
      # must be a weekday and land inside that window.
      target_date = next_bookable_weekday(5)

      params = %{
        form_data: %{},
        meeting_params: %{
          date: Date.to_iso8601(target_date),
          time: "14:00",
          duration: "30min",
          user_timezone: "Europe/Berlin"
        }
      }

      assert {:ok, updated} =
               Orchestrator.submit_booking(params,
                 is_rescheduling: true,
                 reschedule_uid: original.uid,
                 organizer_user_id: user.id
               )

      assert updated.id == original.id

      assert [job] = all_enqueued(worker: CalendarEventWorker)
      assert job.args["action"] == "update"
      assert job.args["meeting_id"] == original.id
    end

    test "returns a descriptive error when the reschedule uid does not exist", %{user: user} do
      # The domain layer surfaces the semantic :meeting_not_found atom — the
      # web layer, not the domain layer, renders it to display text.
      assert {:error, :meeting_not_found} =
               Orchestrator.submit_booking(
                 %{form_data: %{}, meeting_params: %{}},
                 is_rescheduling: true,
                 reschedule_uid: "nope",
                 organizer_user_id: user.id
               )
    end
  end

  describe "get_meeting_for_reschedule/2" do
    test "returns the meeting when the organiser matches and policy allows it", %{user: user} do
      meeting = insert_future_meeting(user, nil)

      assert {:ok, fetched} = Orchestrator.get_meeting_for_reschedule(meeting.uid, user.id)
      assert fetched.id == meeting.id
    end

    test "returns an error when policy blocks the reschedule", %{user: user} do
      # A cancelled meeting fails `Policy.can_reschedule_meeting?/1`
      # regardless of organiser identity.
      meeting =
        insert(:meeting,
          uid: UUID.generate(),
          organizer_user_id: user.id,
          organizer_email: "organiser@example.com",
          status: "cancelled",
          start_time: future_datetime(3, :day),
          end_time: DateTime.add(future_datetime(3, :day), 30, :minute)
        )

      assert {:error, {:not_reschedulable, :cancelled}} =
               Orchestrator.get_meeting_for_reschedule(meeting.uid, user.id)
    end

    # The page that pre-fills the reschedule form and draws its grid applies
    # the same rule the submit does, so it does not offer to move a booking
    # the submit would then refuse.
    test "refuses an expired booking, as the reschedule submit does", %{user: user} do
      meeting = insert_future_meeting(user, nil)
      {:ok, expired} = MeetingQueries.update_meeting_status(meeting, %{status: "expired"})

      assert {:error, {:not_reschedulable, :expired}} =
               Orchestrator.get_meeting_for_reschedule(expired.uid, user.id)
    end
  end

  # ----- helpers -----

  defp insert_future_meeting(user, nil) do
    start_time = future_datetime(3, :day)

    insert(:meeting,
      uid: UUID.generate(),
      organizer_user_id: user.id,
      organizer_email: "organiser@example.com",
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute),
      duration: 30,
      status: "confirmed"
    )
  end

  defp insert_future_meeting(user, meeting_type) do
    start_time = future_datetime(3, :day)

    insert(:meeting,
      uid: UUID.generate(),
      organizer_user_id: user.id,
      organizer_email: "organiser@example.com",
      meeting_type_id: meeting_type.id,
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute),
      duration: 30,
      status: "confirmed"
    )
  end

  # Reports every fresh calendar read to the test process; the read runs in a
  # task, so it is counted by message rather than by Mox's call count.
  defp count_fresh_fetches(response) do
    test_pid = self()

    Mox.stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn user_id, _start, _end ->
      send(test_pid, {:fresh_fetch, user_id})
      response.()
    end)
  end

  defp video_submit(user, meeting_type) do
    %{
      form_data: %{"name" => "Attendee", "email" => "attendee@example.com", "message" => ""},
      meeting_params: %{
        date: Date.add(Date.utc_today(), 1),
        time: "11:00",
        duration: "30min",
        user_timezone: "Europe/Berlin",
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id,
        with_video_room: true
      }
    }
  end

  defp future_datetime(amount, unit) do
    DateTime.utc_now() |> DateTime.add(amount, unit) |> DateTime.truncate(:second)
  end
end
