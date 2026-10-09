defmodule Tymeslot.Integrations.Calendar.BookingWindowReachTest do
  @moduledoc """
  The calendar fetch behind the booking page reaches two days past the last
  bookable date, so a meeting starting on that date and running for up to a
  day is checked against the events it runs into.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :availability

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.CalendarMock
  alias Tymeslot.Integrations.Calendar.Events

  setup :set_mox_from_context
  setup :verify_on_exit!

  test "the fetch ends two days after the longest booking window" do
    host = create_bookable_profile()
    test_pid = self()

    expect(CalendarMock, :get_events_for_range_fresh, fn _user_id, start_date, end_date ->
      send(test_pid, {:fetched, start_date, end_date})
      {:ok, []}
    end)

    Events.get_calendar_events_from_context(Date.utc_today(), host.user.id, %{
      organizer_profile: host.profile
    })

    today = Date.utc_today()
    assert_receive {:fetched, ^today, end_date}
    assert end_date == Date.add(today, host.schedule.advance_booking_days + 2)
  end
end
