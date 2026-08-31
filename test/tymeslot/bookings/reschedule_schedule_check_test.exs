defmodule Tymeslot.Bookings.RescheduleScheduleCheckTest do
  @moduledoc """
  Regression coverage for the reschedule path enforcing the organiser's
  weekly availability and never taking the meeting's duration from the
  request.

  Before this, `Reschedule.execute/4` ran no schedule check at all: an
  attendee holding a legitimate reschedule link could move a meeting to a
  time the organiser's schedule never offered (outside business hours, on a
  day off, inside a break, or onto an "unavailable" override), and the new
  duration was taken from the attendee-supplied URL slug rather than the
  meeting's own persisted duration.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo
  @moduletag :bookings

  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.MeetingTypes
  alias Tymeslot.TestMocks

  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.MeetingTestHelpers

  setup do
    TestMocks.setup_email_mocks()
    :ok
  end

  describe "the organiser's weekly availability" do
    test "refuses a reschedule to a time outside it" do
      # Weekdays only, 09:00-17:00 — a narrow, unambiguous window.
      %{user: user} =
        create_bookable_profile(
          timezone: "Etc/UTC",
          days: [1, 2, 3, 4, 5],
          hours: %{is_available: true, start_time: ~T[09:00:00], end_time: ~T[17:00:00]}
        )

      meeting = insert_meeting_for_user(user)

      # 3am, deep inside the closed window, on a day the schedule offers.
      target_date = next_bookable_weekday(5)

      new_params = %{
        date: Date.to_string(target_date),
        time: "3:00 AM",
        duration: "60min",
        user_timezone: "Etc/UTC"
      }

      assert {:error, :slot_taken} =
               Reschedule.execute(meeting.uid, new_params, %{}, meeting.organizer_user_id)

      # The meeting must stay exactly where it was — the schedule check must
      # refuse before any time is written.
      assert {:ok, unchanged} = MeetingQueries.get_meeting(meeting.id)
      assert DateTime.compare(unchanged.start_time, meeting.start_time) == :eq
    end

    test "succeeds for a valid in-window reschedule" do
      %{user: user} =
        create_bookable_profile(
          timezone: "Etc/UTC",
          days: [1, 2, 3, 4, 5],
          hours: %{is_available: true, start_time: ~T[09:00:00], end_time: ~T[17:00:00]}
        )

      meeting = insert_meeting_for_user(user)
      target_date = next_bookable_weekday(5)

      new_params = %{
        date: Date.to_string(target_date),
        time: "10:00 AM",
        duration: "60min",
        user_timezone: "Etc/UTC"
      }

      assert {:ok, updated} =
               Reschedule.execute(meeting.uid, new_params, %{}, meeting.organizer_user_id)

      assert DateTime.to_date(updated.start_time) == target_date
      assert updated.start_time.hour == 10
    end
  end

  describe "reschedule enforcement duration matches the display grid" do
    test "accepts a slot offered by the meeting type's current duration after the type's duration changed" do
      %{user: user} =
        create_bookable_profile(
          timezone: "Etc/UTC",
          days: [1, 2, 3, 4, 5],
          hours: %{is_available: true, start_time: ~T[09:00:00], end_time: ~T[17:00:00]}
        )

      meeting_type = insert(:meeting_type, user: user, duration_minutes: 30)

      start_time = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          meeting_type_id: meeting_type.id,
          duration: 30,
          start_time: start_time,
          end_time: DateTime.add(start_time, 30, :minute)
        )

      # The host edits the meeting type's duration after the booking exists:
      # the reschedule page's grid now steps by 45 minutes even though the
      # meeting itself stays 30 minutes long.
      {:ok, _meeting_type} =
        MeetingTypes.update_meeting_type(meeting_type, %{duration_minutes: 45})

      target_date = next_bookable_weekday(5)

      # 09:45 is off the original 30-minute lattice (09:00, 09:30, 10:00, ...)
      # but is exactly what the 45-minute grid the page now renders offers.
      new_params = %{
        date: Date.to_string(target_date),
        time: "9:45 AM",
        duration: "45min",
        user_timezone: "Etc/UTC"
      }

      assert {:ok, updated} =
               Reschedule.execute(meeting.uid, new_params, %{}, meeting.organizer_user_id)

      assert updated.start_time.hour == 9
      assert updated.start_time.minute == 45
      # The meeting's own duration is never changed by a reschedule.
      assert updated.duration == 30
    end
  end

  describe "duration authority on reschedule" do
    test "keeps the original meeting's duration even after its meeting type is deleted" do
      %{user: user} = create_always_bookable_profile()

      meeting_type = insert(:meeting_type, user: user, duration_minutes: 60)

      meeting =
        insert_meeting_for_user(user, %{
          meeting_type_id: meeting_type.id,
          duration: 60
        })

      # Simulates `ON DELETE SET NULL` on `meetings_meeting_type_id_fkey`: the
      # meeting type is gone, but the meeting (and its persisted duration)
      # survives with a nil meeting_type_id.
      assert {:ok, _deleted} = MeetingTypes.delete_meeting_type(meeting_type)
      {:ok, meeting} = MeetingQueries.get_meeting(meeting.id)
      assert meeting.meeting_type_id == nil

      target_date = next_bookable_weekday(5)

      # An attacker-controlled URL slug requesting a much longer duration
      # than the meeting ever had.
      new_params = %{
        date: Date.to_string(target_date),
        time: "12:00 PM",
        duration: "480min",
        user_timezone: "Etc/UTC"
      }

      assert {:ok, updated} =
               Reschedule.execute(meeting.uid, new_params, %{}, meeting.organizer_user_id)

      assert updated.duration == 60
      assert DateTime.diff(updated.end_time, updated.start_time, :minute) == 60
    end
  end
end
