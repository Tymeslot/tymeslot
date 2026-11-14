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
  alias Tymeslot.Scheduling.RescheduleContext
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

  describe "rescheduling a session of a series" do
    # A series whose first session is tomorrow, so its year reaches day 40;
    # the session being moved is a later one.
    defp moving(profile, series_id) do
      today = Clock.utc_today()
      first = DateTime.new!(Date.add(today, 1), ~T[09:00:00], "Etc/UTC")
      later = DateTime.new!(Date.add(today, 22), ~T[09:00:00], "Etc/UTC")

      meeting = fn start, position ->
        insert(:meeting,
          organizer_user_id: profile.user_id,
          start_time: start,
          end_time: DateTime.add(start, 3600),
          duration: 60,
          status: "confirmed",
          series_id: series_id,
          series_position: position
        )
      end

      if series_id, do: meeting.(first, 1)
      meeting = meeting.(later, if(series_id, do: 2))

      %{
        profile: profile,
        user_timezone: "Etc/UTC",
        reschedule_uid: meeting.uid,
        reschedule: RescheduleContext.new(meeting, nil)
      }
    end

    defp series_id(profile) do
      first = DateTime.new!(Date.add(Clock.utc_today(), 1), ~T[09:00:00], "Etc/UTC")

      insert(:booking_series,
        organizer_user: nil,
        organizer_user_id: profile.user_id,
        first_start_at: first
      ).id
    end

    test "offers the day past the window, by date and by month",
         %{profile: profile, day: day} do
      request = moving(profile, series_id(profile))

      assert {:ok, slots} = Offer.slots_for_date(request, Date.to_iso8601(day), 60)
      assert "10:00 AM" in slots

      assert {:ok, days} = Offer.days_in_range(request, day, day, 60)
      assert days[Date.to_iso8601(day)] == true
    end

    test "a meeting outside a series keeps to the window", %{profile: profile, day: day} do
      request = moving(profile, nil)

      assert {:ok, []} = Offer.slots_for_date(request, Date.to_iso8601(day), 60)
      assert {:ok, days} = Offer.days_in_range(request, day, day, 60)
      refute days[Date.to_iso8601(day)]
    end
  end
end
