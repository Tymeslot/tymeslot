defmodule Tymeslot.MeetingTypes.OfferedTimesBookingTest do
  @moduledoc """
  A one-to-one meeting type with fixed dates, from the offer to the booking:
  the booking page offers only the times its host listed, booking one makes
  an ordinary meeting that hides it, cancelling that meeting offers it
  again, and the host's calendar, notice and buffers still apply. The
  schedule has no weekly hours at all, so it can never be why a time is
  offered.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :meeting_types
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers, only: [create_bookable_profile: 1]
  import Tymeslot.Factory

  alias Tymeslot.Availability.{Offer, TimeSlots}
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.Cancellation
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.OfferedTimes
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    AvailabilityCache.clear_all()
    stub_calendar([])

    # Open on no weekday: only the offered times can put anything on offer.
    %{user: user, profile: profile, schedule: schedule} =
      create_bookable_profile(timezone: "Etc/UTC", days: [])

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Consultation",
        duration_minutes: 30,
        max_participants: 1,
        fixed_dates: true,
        is_active: true
      )

    day = Date.add(Date.utc_today(), 10)

    for time <- [~T[09:00:00], ~T[14:00:00], ~T[20:30:00]] do
      {:ok, _offered} = OfferedTimes.add(meeting_type, user.id, DateTime.new!(day, time))
    end

    %{user: user, profile: profile, schedule: schedule, meeting_type: meeting_type, day: day}
  end

  defp stub_calendar(events) do
    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, events}
    end)
  end

  defp offered(ctx, date \\ nil) do
    AvailabilityCache.clear_all()
    request = %{profile: ctx.profile, user_timezone: "Etc/UTC", meeting_type: ctx.meeting_type}
    {:ok, slots} = Offer.slots_for_date(request, Date.to_iso8601(date || ctx.day), 30)
    slots
  end

  defp book(ctx, time, date \\ nil) do
    Create.execute(
      %{
        date: date || ctx.day,
        time: time,
        duration: "30min",
        user_timezone: "Etc/UTC",
        organizer_user_id: ctx.user.id,
        meeting_type_id: ctx.meeting_type.id
      },
      %{"name" => "Ada Guest", "email" => "ada-#{System.unique_integer([:positive])}@example.com"}
    )
  end

  test "offers exactly the listed times, on no weekly hours at all", ctx do
    assert offered(ctx) == ["9:00 AM", "2:00 PM", "8:30 PM"]
    assert offered(ctx, Date.add(ctx.day, 1)) == []
  end

  test "booking a time makes an ordinary meeting, which hides it until it is cancelled", ctx do
    assert {:ok, meeting} = book(ctx, "14:00")

    assert meeting.status == :confirmed
    assert meeting.start_time == DateTime.new!(ctx.day, ~T[14:00:00])
    refute meeting.planned

    assert offered(ctx) == ["9:00 AM", "8:30 PM"]
    assert {:error, _taken} = book(ctx, "14:00")

    {:ok, _cancelled} = Cancellation.cancel(meeting, ctx.user.id, :none)

    assert offered(ctx) == ["9:00 AM", "2:00 PM", "8:30 PM"]
  end

  test "a time that is not offered is refused, though it would fit the day", ctx do
    assert {:error, _not_offered} = book(ctx, "10:00")
    assert Repo.aggregate(MeetingSchema, :count) == 0
  end

  test "a calendar event hides the time it overlaps", ctx do
    stub_calendar([
      %{
        uid: "dentist",
        summary: "Dentist",
        start_time: DateTime.new!(ctx.day, ~T[08:45:00]),
        end_time: DateTime.new!(ctx.day, ~T[09:15:00]),
        status: :confirmed,
        transparency: "opaque"
      }
    ])

    assert offered(ctx) == ["2:00 PM", "8:30 PM"]
  end

  test "the minimum notice still applies", ctx do
    # The schedule asks for three hours' notice; a time one hour away is
    # listed but not offered, and refused when booked anyway.
    soon = DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.truncate(:second)
    soon = %{soon | second: 0}
    later = DateTime.add(soon, 5, :hour)

    {:ok, _soon} = OfferedTimes.add(ctx.meeting_type, ctx.user.id, soon)
    {:ok, _later} = OfferedTimes.add(ctx.meeting_type, ctx.user.id, later)

    refute TimeSlots.format_datetime_slot(soon) in offered(ctx, DateTime.to_date(soon))
    assert TimeSlots.format_datetime_slot(later) in offered(ctx, DateTime.to_date(later))

    assert {:error, _too_soon} =
             book(ctx, Calendar.strftime(soon, "%H:%M"), DateTime.to_date(soon))
  end

  test "time off closes an offered time", ctx do
    insert(:time_off_period,
      profile: ctx.profile,
      starts_on: ctx.day,
      ends_on: ctx.day,
      start_time: ~T[13:00:00],
      end_time: ~T[15:00:00]
    )

    assert offered(ctx) == ["9:00 AM", "8:30 PM"]
  end

  test "the type's time lands on the booker's own date", ctx do
    # 20:30 UTC is 05:30 the next morning in Tokyo.
    request = %{profile: ctx.profile, user_timezone: "Asia/Tokyo", meeting_type: ctx.meeting_type}
    next = Date.to_iso8601(Date.add(ctx.day, 1))

    AvailabilityCache.clear_all()
    assert {:ok, ["5:30 AM"]} = Offer.slots_for_date(request, next, 30)
  end
end
