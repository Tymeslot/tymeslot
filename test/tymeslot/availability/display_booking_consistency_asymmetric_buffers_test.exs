defmodule Tymeslot.Availability.DisplayBookingConsistencyAsymmetricBuffersTest do
  @moduledoc """
  The display, the submit-time calendar check and the database conflict check
  must agree when a schedule's before and after buffers differ.

  This is the asymmetric companion to `DisplayBookingConsistencyTest`, split out
  to keep that module under the size limit. A path that pads the wrong side of
  the new booking disagrees with the others: it offers a time the submit
  refuses, or refuses one the page offered.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Bookings.{CalendarCheck, Create, Policy}
  alias Tymeslot.CalendarMock
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    :ok
  end

  # Before and after differ, so any path that pads the wrong side of the new
  # booking disagrees with the others: it offers a time the submit refuses, or
  # refuses one the page offered. Busy 12:00-12:30, 20 minutes wanted before a
  # booking and 10 after it, 30-minute meetings on a 15-minute grid:
  #
  #   11:15  [10:55, 11:55]  clear           offered
  #   11:30  [11:10, 12:10]  after-buffer    hidden
  #   12:30  [12:10, 13:10]  before-buffer   hidden
  #   12:45  [12:25, 13:25]  before-buffer   hidden
  #   13:00  [12:40, 13:40]  clear           offered
  #
  # Swapping the two offers 12:45 and hides 11:15; applying either value to
  # both sides gets one of them wrong as well.
  describe "the invariant under asymmetric buffers" do
    @asymmetric_expectations [
      {"11:15 AM", true},
      {"11:30 AM", false},
      {"12:30 PM", false},
      {"12:45 PM", false},
      {"1:00 PM", true}
    ]

    setup do
      %{user: user, profile: profile, schedule: schedule} =
        create_always_bookable_profile(timezone: "Etc/UTC")

      schedule
      |> Changeset.change(
        buffer_before_minutes: 20,
        buffer_after_minutes: 10,
        min_advance_hours: 0
      )
      |> Repo.update!()

      meeting_type =
        insert(:meeting_type, user: user, duration_minutes: 30, slot_interval_minutes: 15)

      date = Date.add(Date.utc_today(), 10)

      %{user: user, profile: profile, meeting_type: meeting_type, date: date}
    end

    test "a calendar event: the display and the submit-time calendar check agree",
         %{user: user, profile: profile, meeting_type: meeting_type, date: date} do
      busy = %{
        uid: "busy-#{System.unique_integer([:positive])}",
        start_time: DateTime.new!(date, ~T[12:00:00], "Etc/UTC"),
        end_time: DateTime.new!(date, ~T[12:30:00], "Etc/UTC"),
        status: "confirmed",
        transparency: "opaque",
        summary: "Busy"
      }

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
        {:ok, [busy]}
      end)

      offered = offered(profile, date, "30min", meeting_type: meeting_type)
      config = Policy.scheduling_config(user.id, meeting_type)

      for {time, expected?} <- @asymmetric_expectations do
        assert time in offered == expected?, "display: #{time} offered? expected #{expected?}"

        slot_start = DateTime.new!(date, TimeSlots.parse_time_slot(time), "Etc/UTC")

        slot = %{
          organizer_user_id: user.id,
          start_datetime: slot_start,
          end_datetime: DateTime.add(slot_start, 30, :minute)
        }

        assert CalendarCheck.probe(slot, config) == :ok == expected?,
               "calendar check: #{time} free? expected #{expected?}"
      end

      assert {:error, :slot_taken} = book_at(user, meeting_type, date, "12:45 PM")

      assert {:ok, %MeetingSchema{status: "confirmed"}} =
               book_at(user, meeting_type, date, "11:15 AM")
    end

    test "an existing booking: the display and the database conflict check agree",
         %{user: user, profile: profile, meeting_type: meeting_type, date: date} do
      TestMocks.stub_no_calendar_events()

      booked_start = DateTime.new!(date, ~T[12:00:00], "Etc/UTC")

      insert(:meeting,
        organizer_user_id: user.id,
        start_time: booked_start,
        end_time: DateTime.add(booked_start, 30, :minute)
      )

      offered = offered(profile, date, "30min", meeting_type: meeting_type)

      for {time, expected?} <- @asymmetric_expectations do
        assert time in offered == expected?, "display: #{time} offered? expected #{expected?}"
      end

      # The calendar holds nothing, so only the meetings table can refuse these.
      assert {:error, :slot_taken} = book_at(user, meeting_type, date, "11:30 AM")
      assert {:error, :slot_taken} = book_at(user, meeting_type, date, "12:45 PM")
      assert {:ok, %MeetingSchema{}} = book_at(user, meeting_type, date, "1:00 PM")
      assert {:ok, %MeetingSchema{}} = book_at(user, meeting_type, date, "11:15 AM")
    end

    defp book_at(user, meeting_type, date, time) do
      Create.execute(
        %{
          date: date,
          time: time,
          duration: "30min",
          user_timezone: "Etc/UTC",
          organizer_user_id: user.id,
          meeting_type_id: meeting_type.id
        },
        %{
          "name" => "Asymmetric Attendee",
          "email" => "asymmetric-#{System.unique_integer([:positive])}@example.com",
          "message" => "Booking around lopsided buffers"
        }
      )
    end
  end
end
