defmodule Tymeslot.Availability.BookingLimitsFarZonesTest do
  @moduledoc """
  A booking cap judged for a booker more than a day away from the host.

  Zones sit up to 26 hours apart, so a slot listed under a booker's date can
  fall on a host date two days away from it. The page has to count the
  bookings on that host date, or it offers a slot the submit then refuses
  for the cap. Each case pins the page (one date and the month view) and the
  submit to the same answer.

  The dates sit on a Sunday at the end of a month and the Monday after it, so
  no enclosing week or month the page reads for other reasons pulls the
  host's date in by accident. The clock is frozen so those dates stay inside
  the booking window.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :bookings
  @moduletag :integration

  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Test.ClockHelpers

  alias Tymeslot.Availability.Offer
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()
    AvailabilityCache.clear_all()
    freeze_clock(~U[2027-01-20 12:00:00Z])
    :ok
  end

  test "a booker far east of the host sees the host's full Sunday as full" do
    # Sunday 23:00 to midnight in Pago Pago (UTC-11) is 00:00 to 01:00 on
    # Tuesday in Kiritimati (UTC+14).
    host = capped_host("Pacific/Pago_Pago", 7)
    booker = "Pacific/Kiritimati"
    date = ~D[2027-02-02]

    assert offered(host.profile, date, 30, timezone: booker) == ["12:00 AM", "12:30 AM"]
    assert available_day?(host, date, booker)

    insert_booking(host, DateTime.new!(~D[2027-01-31], ~T[10:00:00], "Pacific/Pago_Pago"))

    assert offered(host.profile, date, 30, timezone: booker) == []
    refute available_day?(host, date, booker)
    assert {:error, :booking_limit_reached} = book(host, date, "12:30 AM", booker)
  end

  test "a booker far west of the host sees the host's full Monday as full" do
    # Monday midnight to 01:00 in Kiritimati is 23:00 to midnight on Saturday
    # in Pago Pago.
    host = capped_host("Pacific/Kiritimati", 1)
    booker = "Pacific/Pago_Pago"
    date = ~D[2027-01-30]

    assert offered(host.profile, date, 30, timezone: booker) == ["11:00 PM", "11:30 PM"]
    assert available_day?(host, date, booker)

    insert_booking(host, DateTime.new!(~D[2027-02-01], ~T[10:00:00], "Pacific/Kiritimati"))

    assert offered(host.profile, date, 30, timezone: booker) == []
    refute available_day?(host, date, booker)
    assert {:error, :booking_limit_reached} = book(host, date, "11:30 PM", booker)
  end

  # One booking a day, and one hour of hours on `day_of_week`, from 23:00 to
  # midnight in Pago Pago or from midnight to 01:00 in Kiritimati.
  defp capped_host("Pacific/Pago_Pago" = timezone, day_of_week) do
    capped_host(timezone, day_of_week, %{
      start_time: ~T[23:00:00],
      end_time: ~T[00:00:00],
      ends_next_day: true
    })
  end

  defp capped_host("Pacific/Kiritimati" = timezone, day_of_week) do
    capped_host(timezone, day_of_week, %{start_time: ~T[00:00:00], end_time: ~T[01:00:00]})
  end

  defp capped_host(timezone, day_of_week, hours) do
    create_bookable_profile(
      timezone: timezone,
      days: [day_of_week],
      hours: Map.put(hours, :is_available, true),
      profile: %{max_bookings_per_day: 1}
    )
  end

  defp insert_booking(host, start_time) do
    start_time = DateTime.shift_zone!(start_time, "Etc/UTC")

    insert(:meeting,
      organizer_user_id: host.user.id,
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute),
      duration: 30,
      status: "confirmed"
    )

    AvailabilityCache.clear_all()
  end

  defp available_day?(host, date, booker) do
    request = %{profile: host.profile, user_timezone: booker}
    {:ok, days} = Offer.days_in_range(request, date, date, 30)
    Map.fetch!(days, Date.to_iso8601(date))
  end

  defp book(host, date, time, booker) do
    Create.execute(
      %{
        date: date,
        time: time,
        duration: "30min",
        user_timezone: booker,
        organizer_user_id: host.user.id,
        meeting_type_id: nil
      },
      %{"name" => "Far Away", "email" => "far@example.com", "message" => ""}
    )
  end
end
