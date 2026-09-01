defmodule Tymeslot.Bookings.CreateAdHocTest do
  # async: false — one test patches Oban.insert/1 with :meck to simulate a
  # failed enqueue, and :meck replaces the module globally for every process.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Bookings.CreateAdHoc
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingSchema
  alias TymeslotWeb.Endpoint

  @moduletag :bookings

  describe "execute/1" do
    setup do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "adhoc-host", full_name: "Ada Host")

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

      %{user: user, profile: profile, base_params: base_params}
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

    test "populates organizer fields from profile", %{
      base_params: params,
      user: user,
      profile: profile
    } do
      assert {:ok, meeting} = CreateAdHoc.execute(params)
      assert meeting.organizer_user_id == user.id
      assert meeting.organizer_name == profile.full_name
      assert meeting.organizer_email == user.email
    end

    test "computes duration from start/end times", %{base_params: params} do
      assert {:ok, meeting} = CreateAdHoc.execute(params)
      assert meeting.duration == 120
    end

    test "generates uid and action URLs", %{base_params: params, profile: profile} do
      assert {:ok, meeting} = CreateAdHoc.execute(params)
      assert {:ok, _uuid} = UUID.cast(meeting.uid)

      base = "#{Endpoint.url()}/#{profile.username}/meeting/#{meeting.uid}"
      assert meeting.view_url == base
      assert meeting.reschedule_url == base <> "/reschedule"
      assert meeting.cancel_url == base <> "/cancel"
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

    test "routes attendee invitation through AttendeeNotifications with defaults",
         %{base_params: params} do
      assert {:ok, meeting} = CreateAdHoc.execute(params)

      # Meeting is persisted with default notification-tracking columns
      assert meeting.ical_sequence == 0
      assert meeting.last_notified_state == %{}

      # An EmailWorker job for the attendee calendar invitation is enqueued
      assert_enqueued(
        worker: Tymeslot.Workers.EmailWorker,
        args: %{"attendee_email" => "jane@example.com"}
      )
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

    test "invites the attendee without waiting on the video room", %{
      base_params: params,
      user: user
    } do
      vi = insert(:video_integration, user: user)
      params = %{params | video_integration_id: vi.id}

      assert {:ok, meeting} = CreateAdHoc.execute(params)

      # The iCal invitation carries the event's time and location, not the join
      # link, so it goes out on the video path too rather than waiting for a
      # room that may take days to arrive.
      assert_enqueued(
        worker: Tymeslot.Workers.EmailWorker,
        args: %{
          "action" => "send_calendar_invitation",
          "attendee_email" => "jane@example.com",
          "event_uid" => meeting.uid,
          "method" => "request",
          "sequence" => 0
        }
      )

      # The meeting.created fan-out is the one side effect that *is* deferred to
      # the worker, so the booking is not announced from here.
      assert Repo.reload!(meeting).announced_at == nil

      refute_enqueued(
        worker: Tymeslot.Workers.EmailWorker,
        args: %{"action" => "send_confirmation_emails"}
      )
    end

    test "invites the attendee and announces inline when the video room job cannot be enqueued",
         %{base_params: params, user: user} do
      vi = insert(:video_integration, user: user)
      params = %{params | video_integration_id: vi.id}

      # Only the video room insert fails; every other enqueue on this path (the
      # invitation and the confirmation emails) must still reach the queue.
      :meck.new(Oban, [:passthrough])

      :meck.expect(Oban, :insert, fn changeset ->
        if Changeset.get_field(changeset, :worker) == "Tymeslot.Workers.VideoRoomWorker" do
          {:error, :queue_unavailable}
        else
          :meck.passthrough([changeset])
        end
      end)

      meeting =
        try do
          assert {:ok, meeting} = CreateAdHoc.execute(params)
          meeting
        after
          :meck.unload(Oban)
        end

      refute_enqueued(worker: Tymeslot.Workers.VideoRoomWorker)

      assert_enqueued(
        worker: Tymeslot.Workers.EmailWorker,
        args: %{
          "action" => "send_calendar_invitation",
          "attendee_email" => "jane@example.com",
          "event_uid" => meeting.uid,
          "method" => "request",
          "sequence" => 0
        }
      )

      # No worker is left to raise meeting.created, so the booking is announced
      # here instead.
      assert Repo.reload!(meeting).announced_at

      assert_enqueued(
        worker: Tymeslot.Workers.EmailWorker,
        args: %{"action" => "send_confirmation_emails", "meeting_id" => meeting.id}
      )
    end

    test "attaches guest emails and schedules notifications", %{base_params: params} do
      params =
        Map.put(params, :guest_emails, ["g1@example.com", "g2@example.com"])

      assert {:ok, meeting} = CreateAdHoc.execute(params)

      emails = meeting.id |> Meetings.list_meeting_guests() |> Enum.map(& &1.email) |> Enum.sort()
      assert emails == ["g1@example.com", "g2@example.com"]

      assert_enqueued(worker: Tymeslot.Workers.EmailWorker)
    end

    test "creates zero guests when guest_emails is empty", %{base_params: params} do
      params = Map.put(params, :guest_emails, [])

      assert {:ok, meeting} = CreateAdHoc.execute(params)
      assert Meetings.list_meeting_guests(meeting.id) == []
    end

    test "creates zero guests when guest_emails key is absent", %{base_params: params} do
      assert {:ok, meeting} = CreateAdHoc.execute(params)
      assert Meetings.list_meeting_guests(meeting.id) == []
    end

    test "rolls the whole meeting back when a guest email is invalid", %{base_params: params} do
      params = Map.put(params, :guest_emails, ["not-a-valid-email"])

      assert {:error, _reason} = CreateAdHoc.execute(params)

      # No meeting persisted (transaction rolled back), so no guests either
      assert Meetings.list_upcoming_meetings() == []
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

    test "rejects the organiser booking themselves as the guest", %{
      base_params: params,
      user: user
    } do
      params = %{params | attendee_email: user.email}

      assert {:error, "The guest email must differ from your own address"} =
               CreateAdHoc.execute(params)
    end

    test "rejects self-booking regardless of case or surrounding whitespace", %{
      base_params: params,
      user: user
    } do
      params = %{params | attendee_email: "  #{String.upcase(user.email)}  "}

      assert {:error, "The guest email must differ from your own address"} =
               CreateAdHoc.execute(params)
    end

    test "a rejected self-booking creates no meeting and schedules no email", %{
      base_params: params,
      user: user
    } do
      before_count = Repo.aggregate(MeetingSchema, :count)

      assert {:error, _reason} = CreateAdHoc.execute(%{params | attendee_email: user.email})

      assert Repo.aggregate(MeetingSchema, :count) == before_count
      refute_enqueued(worker: Tymeslot.Workers.EmailWorker)
    end

    test "still allows a guest address that merely resembles the organiser's", %{
      base_params: params,
      user: user
    } do
      [local, domain] = String.split(user.email, "@", parts: 2)
      params = %{params | attendee_email: "#{local}+guest@#{domain}"}

      assert {:ok, meeting} = CreateAdHoc.execute(params)
      assert meeting.attendee_email == "#{local}+guest@#{domain}"
    end
  end
end
