defmodule Tymeslot.Bookings.CreateAdHocTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Tymeslot.Bookings.CreateAdHoc
  alias Tymeslot.Meetings.MeetingSchema

  @moduletag :bookings

  describe "execute/1" do
    setup do
      user = insert(:user)
      _profile = insert(:profile, user: user)

      base_params = %{
        title: "Quick sync",
        start_time: DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second),
        end_time:
          DateTime.utc_now()
          |> DateTime.add(1, :day)
          |> DateTime.add(2, :hour)
          |> DateTime.truncate(:second),
        attendee_name: "Jane Doe",
        attendee_email: "jane@example.com",
        attendee_timezone: "Europe/Berlin",
        organizer_user_id: user.id,
        calendar_integration_id: nil,
        calendar_path: nil,
        video_integration_id: nil
      }

      %{user: user, base_params: base_params}
    end

    test "creates meeting with nil meeting_type_id", %{base_params: params} do
      assert {:ok, meeting} = CreateAdHoc.execute(params)
      assert %MeetingSchema{} = meeting
      assert meeting.meeting_type_id == nil
      assert meeting.meeting_type == "Quick sync"
      assert meeting.attendee_name == "Jane Doe"
      assert meeting.attendee_email == "jane@example.com"
      assert meeting.status == "confirmed"
    end

    test "populates organizer fields from profile", %{base_params: params, user: user} do
      assert {:ok, meeting} = CreateAdHoc.execute(params)
      assert meeting.organizer_user_id == user.id
      assert is_binary(meeting.organizer_name)
      assert is_binary(meeting.organizer_email)
    end

    test "computes duration from start/end times", %{base_params: params} do
      assert {:ok, meeting} = CreateAdHoc.execute(params)
      assert meeting.duration == 120
    end

    test "generates uid and action URLs", %{base_params: params} do
      assert {:ok, meeting} = CreateAdHoc.execute(params)
      assert is_binary(meeting.uid)
      assert is_binary(meeting.view_url)
      assert is_binary(meeting.reschedule_url)
      assert is_binary(meeting.cancel_url)
    end

    test "schedules calendar event job when calendar_integration_id is set", %{
      base_params: params,
      user: user
    } do
      cal = insert(:calendar_integration, user: user)
      params = %{params | calendar_integration_id: cal.id, calendar_path: "/calendars/main"}
      assert {:ok, meeting} = CreateAdHoc.execute(params)
      assert meeting.calendar_integration_id == cal.id
      assert meeting.calendar_path == "/calendars/main"
      assert_enqueued(worker: Tymeslot.Workers.CalendarEventWorker)
    end

    test "schedules email notifications when no video integration", %{base_params: params} do
      assert {:ok, _meeting} = CreateAdHoc.execute(params)
      assert_enqueued(worker: Tymeslot.Workers.EmailWorker)
    end

    test "schedules video room creation when video_integration_id is set", %{
      base_params: params,
      user: user
    } do
      vi = insert(:video_integration, user: user)
      params = %{params | video_integration_id: vi.id}
      assert {:ok, _meeting} = CreateAdHoc.execute(params)
      assert_enqueued(worker: Tymeslot.Workers.VideoRoomWorker)
    end

    test "returns error when attendee_email is missing", %{base_params: params} do
      params = %{params | attendee_email: nil}
      assert {:error, _reason} = CreateAdHoc.execute(params)
    end

    test "returns error when attendee_name is missing", %{base_params: params} do
      params = %{params | attendee_name: nil}
      assert {:error, _reason} = CreateAdHoc.execute(params)
    end

    test "returns error when end_time is before start_time", %{base_params: params} do
      params = %{params | end_time: DateTime.add(params.start_time, -1, :hour)}
      assert {:error, _reason} = CreateAdHoc.execute(params)
    end

    test "returns error when title is blank", %{base_params: params} do
      params = %{params | title: ""}
      assert {:error, _reason} = CreateAdHoc.execute(params)
    end
  end
end
