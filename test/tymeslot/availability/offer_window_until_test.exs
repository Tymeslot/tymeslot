defmodule Tymeslot.Availability.OfferWindowUntilTest do
  @moduledoc """
  `Offer.slots_for_range/4` with `window_until:`: a range past the host's
  booking window, as a series' later sessions may be. Without the key the
  window ends the offer; with it, the range is offered up to that date, the
  host's calendar is read over the range itself, and a busy time there is
  not offered.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Availability.Offer
  alias Tymeslot.CalendarMock
  alias Tymeslot.Clock
  alias Tymeslot.Repo
  alias Tymeslot.Test.ClockHelpers
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()
    ClockHelpers.freeze_clock(DateTime.utc_now(:second))

    %{profile: profile, schedule: schedule} = create_always_bookable_profile()
    schedule |> Changeset.change(advance_booking_days: 30) |> Repo.update!()

    %{profile: profile, day: Date.add(Clock.utc_today(), 40)}
  end

  defp day_slots(profile, day, extra \\ %{}) do
    request = Map.merge(%{profile: profile, user_timezone: "Etc/UTC"}, extra)
    {:ok, range} = Offer.slots_for_range(request, day, day, 60)
    Map.fetch!(range, Date.to_iso8601(day))
  end

  test "a 30-day window offers nothing on day 40 without window_until", %{profile: p, day: day} do
    assert day_slots(p, day) == []
  end

  test "window_until covering day 40 offers its times", %{profile: profile, day: day} do
    slots = day_slots(profile, day, %{window_until: Date.add(day, 5)})

    assert "10:00 AM" in slots
    assert length(slots) > 10
  end

  test "window_until short of the day still leaves it out", %{profile: profile, day: day} do
    assert day_slots(profile, day, %{window_until: Date.add(day, -2)}) == []
  end

  test "reads the host's calendar over the range and leaves its busy time out",
       %{profile: profile, day: day} do
    busy_start = DateTime.new!(day, ~T[10:00:00], "Etc/UTC")
    test_pid = self()

    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, from, to ->
      send(test_pid, {:read, from, to})

      {:ok,
       [
         TestMocks.mock_calendar_event(
           summary: "Busy",
           start_time: busy_start,
           end_time: DateTime.add(busy_start, 3600)
         )
       ]}
    end)

    slots = day_slots(profile, day, %{window_until: Date.add(day, 5)})

    assert_received {:read, from, to}
    assert Date.compare(from, day) != :gt
    assert Date.compare(to, day) == :gt

    refute "10:00 AM" in slots
    assert "12:00 PM" in slots
  end
end
