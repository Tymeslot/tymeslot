defmodule Tymeslot.Availability.ExtraAvailabilityOfferTest do
  @moduledoc """
  Extra available times through the booking page's own pipeline
  (`Tymeslot.Availability.Offer`), which reads the schedule's overrides once
  for the range (`Calculate.prefetch_schedule_data/4`) and resolves every
  date from that list rather than from a query per date.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability.{ExtraAvailability, Offer}
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()
    AvailabilityCache.clear_all()
    on_exit(&AvailabilityCache.clear_all/0)

    # Open 11:00 to 17:00 UTC, Monday to Friday.
    host = create_bookable_profile(timezone: "Etc/UTC")
    weekday = next_bookable_weekday()
    saturday = Date.add(weekday, 6 - Date.day_of_week(weekday))

    %{host: host, weekday: weekday, saturday: saturday}
  end

  test "a week view offers the extra times from the prefetched overrides", context do
    %{host: host, weekday: weekday, saturday: saturday} = context

    # Inserted first, so the prefetched list holds the extra time ahead of the
    # day's replacement hours: the lookup for those must pass over it.
    {:ok, _evening} = add(host.schedule, weekday, ~T[18:00:00], ~T[19:00:00])

    insert(:availability_override,
      schedule: host.schedule,
      date: weekday,
      override_type: "custom_hours",
      start_time: ~T[10:00:00],
      end_time: ~T[11:00:00]
    )

    {:ok, _morning} = add(host.schedule, saturday, ~T[09:00:00], ~T[10:00:00])

    request = %{profile: host.profile, user_timezone: "Etc/UTC", meeting_type: nil}
    {:ok, days} = Offer.slots_for_range(request, weekday, saturday, 30)

    assert days[Date.to_iso8601(weekday)] == ["10:00 AM", "10:30 AM", "6:00 PM", "6:30 PM"]
    assert days[Date.to_iso8601(saturday)] == ["9:00 AM", "9:30 AM"]
  end

  test "adding an extra time reaches a cached month view at once", context do
    %{host: host, saturday: saturday} = context
    request = %{profile: host.profile, user_timezone: "Etc/UTC"}
    key = Date.to_iso8601(saturday)

    assert {:ok, %{^key => false}} = Offer.days_in_range(request, saturday, saturday, 30)

    {:ok, _extra} = add(host.schedule, saturday, ~T[09:00:00], ~T[10:00:00])

    assert {:ok, %{^key => true}} = Offer.days_in_range(request, saturday, saturday, 30)
  end

  defp add(schedule, date, from, to) do
    ExtraAvailability.add(
      schedule,
      %{date: date, start_time: from, end_time: to},
      Date.utc_today()
    )
  end
end
