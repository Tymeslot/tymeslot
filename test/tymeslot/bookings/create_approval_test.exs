defmodule Tymeslot.Bookings.CreateApprovalTest do
  @moduledoc """
  Booking a meeting type that requires the host's manual approval.

  The assertions worth breaking things over are the negative ones: a held
  booking must not send a confirmation, must not create a video room, and must
  not schedule reminders. Each of those tells the invitee the meeting is on
  when nobody has agreed to it yet.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Mox

  @moduletag :bookings

  alias Tymeslot.Bookings.Create
  alias Tymeslot.Validation.Constraints
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoRoomWorker

  setup :verify_on_exit!

  setup do
    user = insert(:user)
    _profile = insert(:profile)

    # The booking path does a fresh availability check against the host's
    # provider calendars before committing; an empty calendar means no
    # conflicts, which keeps these tests about the approval gate.
    Mox.stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user, _from, _to ->
      {:ok, []}
    end)

    Mox.stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
      {:error, :no_integration}
    end)

    form_data = %{
      "name" => "Test Attendee",
      "email" => "attendee@test.com",
      "message" => "Looking forward to it"
    }

    %{user: user, form_data: form_data}
  end

  defp book(user, form_data, meeting_type, days_ahead \\ 1) do
    params = %{
      date: next_weekday(Date.add(Date.utc_today(), days_ahead)),
      time: "10:00",
      duration: "30min",
      user_timezone: "UTC",
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }

    Create.execute(params, form_data)
  end

  # These tests give the organiser no availability schedule, so the booking
  # path falls back to `Availability.BusinessHours`'s Monday-to-Friday hours.
  # Without this the whole file fails every Saturday and Sunday, because the
  # default `days_ahead` of 1 lands on a weekend and the schedule offers
  # nothing there. Rolling forward keeps `days_ahead` meaning "soon" (1) or
  # "far enough out that the window is not capped" (5), which is what the
  # deadline assertions below actually depend on.
  defp next_weekday(date) do
    case Date.day_of_week(date) do
      day when day <= 5 -> date
      day -> Date.add(date, 8 - day)
    end
  end

  describe "booking a meeting type that requires approval" do
    test "is held rather than confirmed", %{user: user, form_data: form_data} do
      meeting_type = insert(:meeting_type, user: user, requires_approval: true)

      assert {:ok, meeting} = book(user, form_data, meeting_type)
      assert meeting.status == "awaiting_approval"
    end

    test "stamps the clock the host is answering against", %{user: user, form_data: form_data} do
      meeting_type =
        insert(:meeting_type, user: user, requires_approval: true, approval_window_hours: 6)

      assert {:ok, meeting} = book(user, form_data, meeting_type)

      assert %DateTime{} = meeting.approval_requested_at

      assert DateTime.diff(meeting.approval_deadline_at, meeting.approval_requested_at) ==
               6 * 3600
    end

    test "falls back to the default window when the meeting type stores none", %{
      user: user,
      form_data: form_data
    } do
      meeting_type =
        insert(:meeting_type, user: user, requires_approval: true, approval_window_hours: nil)

      # Far enough out that the start-time cap cannot bite; that cap is
      # exercised on its own below.
      assert {:ok, meeting} = book(user, form_data, meeting_type, 5)

      assert DateTime.diff(meeting.approval_deadline_at, meeting.approval_requested_at) ==
               Constraints.default_approval_window_hours() * 3600
    end

    test "never promises a deadline later than the meeting itself", %{
      user: user,
      form_data: form_data
    } do
      meeting_type =
        insert(:meeting_type, user: user, requires_approval: true, approval_window_hours: 336)

      assert {:ok, meeting} = book(user, form_data, meeting_type, 1)

      # A two-week window against a meeting tomorrow would otherwise leave the
      # invitee waiting on a decision that could arrive after their slot.
      assert meeting.approval_deadline_at == meeting.start_time
    end

    test "sends no confirmation email while the host has not answered", %{
      user: user,
      form_data: form_data
    } do
      meeting_type = insert(:meeting_type, user: user, requires_approval: true)

      assert {:ok, _meeting} = book(user, form_data, meeting_type)

      refute_enqueued(worker: EmailWorker, args: %{"action" => "send_confirmation_emails"})
      refute_enqueued(worker: EmailWorker, args: %{"action" => "send_reminder_emails"})
    end

    test "sends the request emails instead of a confirmation", %{
      user: user,
      form_data: form_data
    } do
      meeting_type = insert(:meeting_type, user: user, requires_approval: true)

      assert {:ok, meeting} = book(user, form_data, meeting_type)

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_booking_request_emails", "meeting_id" => meeting.id}
      )
    end

    test "schedules a single nudge halfway through the window", %{
      user: user,
      form_data: form_data
    } do
      meeting_type =
        insert(:meeting_type, user: user, requires_approval: true, approval_window_hours: 10)

      assert {:ok, meeting} = book(user, form_data, meeting_type, 5)

      assert [job] =
               Enum.filter(
                 all_enqueued(worker: EmailWorker),
                 &(&1.args["action"] == "send_booking_approval_nudge")
               )

      # Halfway leaves a host who missed the first email as long again to act.
      expected = DateTime.add(meeting.approval_requested_at, 5 * 3600, :second)
      assert DateTime.compare(DateTime.truncate(job.scheduled_at, :second), expected) == :eq
    end

    test "creates no video room for a booking nobody has agreed to", %{
      user: user,
      form_data: form_data
    } do
      video_int = insert(:video_integration, user: user)

      meeting_type =
        insert(:meeting_type,
          user: user,
          requires_approval: true,
          video_integration: video_int,
          allow_video: true
        )

      assert {:ok, _meeting} = book(user, form_data, meeting_type)

      refute_enqueued(worker: VideoRoomWorker)
    end
  end

  describe "booking a meeting type that does not require approval" do
    test "still confirms on submission and notifies immediately", %{
      user: user,
      form_data: form_data
    } do
      meeting_type = insert(:meeting_type, user: user, requires_approval: false)

      assert {:ok, meeting} = book(user, form_data, meeting_type)

      assert meeting.status == "confirmed"
      assert meeting.approval_requested_at == nil
      assert meeting.approval_deadline_at == nil

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_confirmation_emails", "meeting_id" => meeting.id}
      )
    end
  end
end
