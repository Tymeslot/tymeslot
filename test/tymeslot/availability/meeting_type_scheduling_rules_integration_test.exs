defmodule Tymeslot.Availability.MeetingTypeSchedulingRulesIntegrationTest do
  @moduledoc """
  Two meeting types sharing one availability schedule, one of them overriding
  the schedule's buffers, minimum notice and booking window.

  The user-level guarantee: each type is offered, and accepted at submit, under
  its own rules, and a type with no overrides keeps following its schedule. The
  scenario is the one hosts asked for: a "personal conversation" that wants a
  buffer and half a day's notice, and "quick support" on the same hours with
  neither.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :integration

  import Tymeslot.AvailabilityTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Bookings.Validation
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.TestMocks
  alias TymeslotWeb.Live.Scheduling.OrganizerHelpers

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()

    %{user: user, profile: profile, schedule: schedule} =
      create_always_bookable_profile(timezone: "Etc/UTC")

    schedule =
      schedule
      |> Changeset.change(
        buffer_before_minutes: 10,
        buffer_after_minutes: 10,
        min_advance_hours: 12,
        advance_booking_days: 90
      )
      |> Repo.update!()

    personal =
      insert(:meeting_type,
        user: user,
        name: "Personal conversation",
        duration_minutes: 30,
        slot_interval_minutes: 15
      )

    quick =
      insert(:meeting_type,
        user: user,
        name: "Quick support",
        duration_minutes: 30,
        slot_interval_minutes: 15,
        buffer_before_minutes: 0,
        buffer_after_minutes: 0,
        min_advance_hours: 0,
        advance_booking_days: 300
      )

    %{
      user: user,
      profile: profile,
      schedule: schedule,
      personal: personal,
      quick: quick,
      date: next_bookable_weekday()
    }
  end

  # An existing booking at 12:00-12:30; 30-minute meetings on a 15-minute grid.
  # Personal inherits the schedule's 10 minutes either side, quick support has
  # none:
  #
  #   11:30  [11:20, 12:10] personal: hidden   [11:30, 12:00] quick: offered
  #   12:30  [12:20, 13:10] personal: hidden   [12:30, 13:00] quick: offered
  #   12:45  [12:35, 13:25] personal: offered  quick: offered
  test "each meeting type keeps its own buffers around an existing booking", %{
    user: user,
    profile: profile,
    personal: personal,
    quick: quick,
    date: date
  } do
    booked_start = DateTime.new!(date, ~T[12:00:00], "Etc/UTC")

    insert(:meeting,
      organizer_user_id: user.id,
      start_time: booked_start,
      end_time: DateTime.add(booked_start, 30, :minute)
    )

    personal_offer = offered(profile, date, "30min", meeting_type: personal)
    quick_offer = offered(profile, date, "30min", meeting_type: quick)

    refute "11:30 AM" in personal_offer
    refute "12:30 PM" in personal_offer
    assert "12:45 PM" in personal_offer

    assert "11:30 AM" in quick_offer
    assert "12:30 PM" in quick_offer
    assert "12:45 PM" in quick_offer

    # The submit re-checks under the same rules the page offered.
    assert {:error, :slot_taken} = book_at(user, personal, date, "12:30 PM")
    assert {:ok, %MeetingSchema{}} = book_at(user, quick, date, "12:30 PM")
    assert {:ok, %MeetingSchema{}} = book_at(user, quick, date, "11:30 AM")
  end

  test "minimum notice applies per meeting type", %{user: user, personal: personal, quick: quick} do
    now = ~U[2026-11-04 08:00:00Z]
    in_two_hours = DateTime.add(now, 2, :hour)

    personal_config = Map.put(Schedules.booking_config(user.id, personal), :current_time, now)
    quick_config = Map.put(Schedules.booking_config(user.id, quick), :current_time, now)

    assert {:error, {:too_soon, 12}} =
             Validation.validate_booking_time(in_two_hours, personal_config)

    assert :ok = Validation.validate_booking_time(in_two_hours, quick_config)
  end

  test "the booking window applies per meeting type, on the page and at submit", %{
    user: user,
    profile: profile,
    personal: personal,
    quick: quick
  } do
    assert OrganizerHelpers.booking_window_days(profile, personal) == 90
    assert OrganizerHelpers.booking_window_days(profile, quick) == 300

    {:ok, far_ahead} = DateTime.new(Date.add(Date.utc_today(), 200), ~T[12:00:00], "Etc/UTC")

    assert {:error, {:too_far_ahead, 90}} =
             Validation.validate_booking_time(
               far_ahead,
               Schedules.booking_config(user.id, personal)
             )

    assert :ok =
             Validation.validate_booking_time(far_ahead, Schedules.booking_config(user.id, quick))
  end

  test "a meeting type without overrides follows later changes to its schedule", %{
    user: user,
    schedule: schedule,
    personal: personal,
    quick: quick
  } do
    {:ok, _updated} =
      Schedules.update_policy(schedule, %{buffer_before_minutes: 45, min_advance_hours: 24})

    personal_config = Schedules.booking_config(user.id, personal)
    quick_config = Schedules.booking_config(user.id, quick)

    assert personal_config.buffer_before_minutes == 45
    assert personal_config.min_advance_hours == 24

    assert quick_config.buffer_before_minutes == 0
    assert quick_config.min_advance_hours == 0
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
        "name" => "Rules Attendee",
        "email" => "rules-#{System.unique_integer([:positive])}@example.com",
        "message" => "Booking under per-type rules"
      }
    )
  end
end
