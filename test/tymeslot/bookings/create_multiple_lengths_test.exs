defmodule Tymeslot.Bookings.CreateMultipleLengthsTest do
  @moduledoc """
  A meeting type offering several lengths books the one the booker chose, and
  only a length it offers.
  """

  use Tymeslot.DataCase, async: false
  @moduletag :bookings

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Bookings.Create

  setup :verify_on_exit!

  setup do
    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    %{user: user} = create_always_bookable_profile(timezone: "UTC")

    form_data = %{"name" => "Test Attendee", "email" => "attendee@test.com", "message" => ""}

    %{user: user, form_data: form_data}
  end

  # 10:30 lies on both a 30- and a 90-minute grid counted from midnight, which
  # is where slots start when the type has no interval of its own.
  defp params(user, meeting_type, duration) do
    %{
      date: Date.add(Date.utc_today(), 1),
      time: "10:30",
      duration: duration,
      user_timezone: "UTC",
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }
  end

  test "books the length the booker chose", %{user: user, form_data: form_data} do
    meeting_type =
      insert(:meeting_type, user: user, duration_minutes: 30, extra_lengths_minutes: [60, 90])

    assert {:ok, meeting} = Create.execute(params(user, meeting_type, 90), form_data)

    assert meeting.duration == 90
    assert DateTime.diff(meeting.end_time, meeting.start_time, :minute) == 90
  end

  test "books the type's own duration for a length it does not offer",
       %{user: user, form_data: form_data} do
    meeting_type =
      insert(:meeting_type, user: user, duration_minutes: 30, extra_lengths_minutes: [60])

    assert {:ok, meeting} = Create.execute(params(user, meeting_type, 240), form_data)

    assert meeting.duration == 30
  end
end
