defmodule Tymeslot.Availability.OfferSharedAvailabilityBookedSlotsTest do
  @moduledoc """
  What a combined booking link (`?with=`) offers once its participants
  already have bookings.

  `Tymeslot.Availability.OfferBookedSlotsTest` pins that the host's own
  bookings withdraw their slots whether or not they have reached a calendar. A
  combined link answers for several people, so the same has to hold for each
  of them, in the day list as well as in the month grid.

  The named users were covered before the host was:
  `SharedAvailability.busy_times/3` has always added the bookings they host to
  their calendar events, through the same `MeetingListQueries.list_for_organizer_in_range/3`
  the submit's conflict check relies on. The host's side of the combined month
  grid was not — it still read the calendars alone — and is what the last test
  here pins.

  The calendars are connected but return nothing, which is the state a booking
  sits in until `CalendarEventWorker` has mirrored it: the meetings table is the
  only place the booking shows.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :bookings

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability.Offer
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Scheduling.SharedAvailability
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  @timezone "Etc/UTC"

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()
    AvailabilityCache.clear_all()

    %{user: host, profile: profile} =
      create_bookable_profile(profile: %{username: "marco"}, timezone: @timezone)

    %{user: guest} =
      create_bookable_profile(profile: %{username: "michael"}, timezone: @timezone)

    # Connected, and bookable on their own page — but the calendar returns
    # nothing yet, so a booking on it exists only in the meetings table.
    insert(:calendar_integration, user: guest)
    insert(:meeting_type, user: guest)

    {:ok, guests} = SharedAvailability.resolve(["michael"], host.id)

    %{host: host, guest: guest, profile: profile, guests: guests, date: next_bookable_weekday()}
  end

  describe "slots_for_date/3 with a named user" do
    test "a booking on the named user's own page withdraws the slot", context do
      # Anchor: free for both before the booking, so what follows is the booking.
      assert "11:00 AM" in slots(context)

      book(context.guest, context.date, ~T[11:00:00])

      refute "11:00 AM" in slots(context)
    end
  end

  describe "days_in_range/4 with a named user" do
    test "a day the named user is booked through is no longer bookable", context do
      %{date: date, guest: guest} = context
      other_date = next_weekday_after(date)

      book(guest, date, ~T[09:00:00], 480)

      days = days(context, date, other_date)

      # Anchor: the next day is untouched, so `false` below is the booking.
      assert Map.fetch!(days, Date.to_iso8601(other_date))
      refute Map.fetch!(days, Date.to_iso8601(date))
    end

    test "a day the host is booked through is no longer bookable either", context do
      %{date: date, host: host} = context
      other_date = next_weekday_after(date)

      book(host, date, ~T[09:00:00], 480)

      days = days(context, date, other_date)

      assert Map.fetch!(days, Date.to_iso8601(other_date))
      refute Map.fetch!(days, Date.to_iso8601(date))
    end
  end

  defp request(%{profile: profile, guests: guests}) do
    %{
      profile: profile,
      user_timezone: @timezone,
      reschedule_uid: nil,
      shared_availability_guests: guests
    }
  end

  defp slots(context) do
    AvailabilityCache.clear_all()

    {:ok, slots} =
      context
      |> request()
      |> Offer.slots_for_date(Date.to_iso8601(context.date), 60)

    slots
  end

  defp days(context, start_date, end_date) do
    AvailabilityCache.clear_all()

    {:ok, days} =
      context
      |> request()
      |> Offer.days_in_range(start_date, end_date, 60)

    days
  end

  defp book(user, date, time, duration_minutes \\ 60) do
    start_time = DateTime.new!(date, time, @timezone)

    insert(:meeting,
      organizer_user_id: user.id,
      start_time: start_time,
      end_time: DateTime.add(start_time, duration_minutes, :minute),
      duration: duration_minutes
    )
  end

  defp next_weekday_after(date) do
    next = Date.add(date, 1)

    if Date.day_of_week(next) in 1..5, do: next, else: next_weekday_after(next)
  end
end
