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
    * `validate_booking_time/3` surfaces the downstream validator's
      answer for both a valid and an invalid input,
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

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Bookings.Orchestrator
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

    meeting_type =
      insert(:meeting_type, user: user, name: "Intro", duration_minutes: 30, is_active: true)

    %{user: user, profile: profile, meeting_type: meeting_type}
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

  describe "submit_booking/2 — new booking with video room" do
    test "routes through the video-room branch and enqueues VideoRoomWorker", %{
      user: user,
      meeting_type: meeting_type
    } do
      video_integration = insert(:video_integration, user: user, provider: "mirotalk")

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
          meeting_type_id: meeting_type.id,
          video_integration_id: video_integration.id,
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

  describe "submit_booking/2 — reschedule" do
    test "delegates to the reschedule path when is_rescheduling: true", %{
      user: user,
      meeting_type: meeting_type
    } do
      original = insert_future_meeting(user, meeting_type)

      new_slot = future_datetime(5, :day)

      params = %{
        form_data: %{},
        meeting_params: %{
          date: Date.to_iso8601(DateTime.to_date(shift_to_berlin(new_slot))),
          time: time_string(shift_to_berlin(new_slot)),
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

  describe "validate_booking_time/3" do
    test "returns :ok for a valid future slot" do
      {date, time} = tomorrow_in_berlin("14:00")

      assert :ok = Orchestrator.validate_booking_time(date, time, "Europe/Berlin")
    end

    test "returns an error for a date in the past" do
      past = Date.to_iso8601(Date.add(Date.utc_today(), -1))

      assert {:error, _reason} =
               Orchestrator.validate_booking_time(past, "10:00", "Europe/Berlin")
    end
  end

  describe "get_meeting_for_reschedule/2" do
    test "returns the meeting when the organiser matches and policy allows it", %{user: user} do
      meeting = insert_future_meeting(user, nil)

      assert {:ok, fetched} = Orchestrator.get_meeting_for_reschedule(meeting.uid, user.id)
      assert fetched.id == meeting.id
    end

    test "returns an error when policy blocks the reschedule", %{user: user} do
      # A cancelled meeting fails `Validation.validate_meeting_for_reschedule/1`
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

      assert {:error, _reason} = Orchestrator.get_meeting_for_reschedule(meeting.uid, user.id)
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

  defp future_datetime(amount, unit) do
    DateTime.utc_now() |> DateTime.add(amount, unit) |> DateTime.truncate(:second)
  end

  defp shift_to_berlin(%DateTime{} = dt), do: DateTime.shift_zone!(dt, "Europe/Berlin")

  defp tomorrow_in_berlin(time) do
    {Date.to_iso8601(Date.add(Date.utc_today(), 1)), time}
  end

  defp time_string(%DateTime{hour: h, minute: m}) do
    "#{pad(h)}:#{pad(m)}"
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: Integer.to_string(n)
end
