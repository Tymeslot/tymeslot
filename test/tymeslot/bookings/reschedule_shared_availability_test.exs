defmodule Tymeslot.Bookings.RescheduleSharedAvailabilityTest do
  @moduledoc """
  Rescheduling a booking whose guests include Tymeslot users: the users are
  recovered from the guest list and have to be free for the new time too.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory
  import Tymeslot.MeetingTestHelpers

  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.TestMocks

  @afternoon %{is_available: true, start_time: ~T[13:00:00], end_time: ~T[17:00:00]}

  setup :verify_on_exit!

  setup do
    TestMocks.setup_email_mocks()

    stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
      {:error, :no_integration}
    end)

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    %{user: host} = create_always_bookable_profile(profile: %{username: "marco"})
    meeting = insert_meeting_for_user(host, %{duration: 1_800})

    %{user: michael} =
      create_bookable_profile(
        profile: %{username: "michael"},
        days: Enum.to_list(1..7),
        hours: @afternoon
      )

    insert(:calendar_integration, user: michael)
    insert(:meeting_type, user: michael)

    {:ok, _guests} = Guests.create_for_meeting(meeting.id, [michael.email])

    %{host: host, michael: michael, meeting: meeting, date: next_bookable_weekday()}
  end

  defp new_params(ctx, time) do
    %{date: Date.to_string(ctx.date), time: time, duration: "30min", user_timezone: "Etc/UTC"}
  end

  test "moves the booking to a time the guest user is free for", ctx do
    assert {:ok, updated} =
             Reschedule.execute(ctx.meeting.uid, new_params(ctx, "14:00"), %{}, ctx.host.id)

    assert updated.start_time == DateTime.new!(ctx.date, ~T[14:00:00], "Etc/UTC")
  end

  test "refuses a time outside the guest user's working hours", ctx do
    assert {:error, :slot_taken} =
             Reschedule.execute(ctx.meeting.uid, new_params(ctx, "10:00"), %{}, ctx.host.id)
  end

  test "refuses a time the guest user's calendar is busy for", ctx do
    busy_start = DateTime.new!(ctx.date, ~T[14:00:00], "Etc/UTC")

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok,
       [%{uid: "other-event", start_time: busy_start, end_time: DateTime.add(busy_start, 3600)}]}
    end)

    assert {:error, :slot_taken} =
             Reschedule.execute(ctx.meeting.uid, new_params(ctx, "14:00"), %{}, ctx.host.id)
  end

  test "does not treat the booking's own invitation in the guest's calendar as a conflict", ctx do
    busy_start = DateTime.new!(ctx.date, ~T[14:00:00], "Etc/UTC")

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok,
       [%{uid: ctx.meeting.uid, start_time: busy_start, end_time: DateTime.add(busy_start, 3600)}]}
    end)

    assert {:ok, _updated} =
             Reschedule.execute(ctx.meeting.uid, new_params(ctx, "14:00"), %{}, ctx.host.id)
  end

  test "ignores guests who are not Tymeslot users", ctx do
    other = insert_meeting_for_user(ctx.host, %{duration: 1_800, start_offset: 3 * 86_400})
    {:ok, _guests} = Guests.create_for_meeting(other.id, ["friend@example.com"])

    assert {:ok, _updated} =
             Reschedule.execute(other.uid, new_params(ctx, "10:00"), %{}, ctx.host.id)
  end
end
