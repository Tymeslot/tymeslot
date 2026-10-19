defmodule Tymeslot.Availability.AvailabilityChangedTest do
  @moduledoc """
  A host's settings change while their booking page is cached.

  The month view's days are cached per host, and neither the host's timezone
  nor their booking limits are part of the key. A change to either reaches
  the next page view at once, rather than after the cache's lifetime.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :profiles

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability.Offer
  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Profiles
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  @booker_timezone "Etc/UTC"

  setup do
    TestMocks.setup_all_mocks()
    AvailabilityCache.clear_all()
    on_exit(&AvailabilityCache.clear_all/0)

    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)

    # Open 11:00 to 17:00, Monday to Friday, on the host's clock.
    %{user: user, profile: profile} = create_bookable_profile(timezone: "Etc/UTC")
    monday = monday_after(next_bookable_weekday())

    %{user: user, profile: profile, monday: monday}
  end

  test "a host's new timezone reaches the booking page's month view at once", context do
    %{profile: profile, monday: monday} = context
    sunday = Date.add(monday, -1)

    assert days(profile, sunday, monday) == %{
             Date.to_iso8601(sunday) => false,
             Date.to_iso8601(monday) => true
           }

    # Monday 11:00 in Kiritimati (UTC+14) is Sunday 21:00 for this booker.
    {:ok, moved} = Profiles.update_timezone(profile, "Pacific/Kiritimati")

    assert days(moved, sunday, monday)[Date.to_iso8601(sunday)] == true
  end

  test "a new daily booking cap closes a day that already has a booking", context do
    %{user: user, profile: profile, monday: monday} = context
    booked_at = DateTime.new!(monday, ~T[12:00:00], "Etc/UTC")

    insert(:meeting,
      organizer_user_id: user.id,
      start_time: booked_at,
      end_time: DateTime.add(booked_at, 30, :minute)
    )

    assert days(profile, monday, monday) == %{Date.to_iso8601(monday) => true}

    {:ok, capped} = Profiles.update_booking_limit(profile, :max_bookings_per_day, 1)

    assert days(capped, monday, monday) == %{Date.to_iso8601(monday) => false}
  end

  # The month view as a fresh page view requests it, with the profile as the
  # page loads it.
  defp days(profile, first, last) do
    request = %{profile: profile, user_timezone: @booker_timezone}
    {:ok, days} = Offer.days_in_range(request, first, last, 30)
    days
  end

  defp monday_after(date), do: Date.add(date, 8 - Date.day_of_week(date))
end
