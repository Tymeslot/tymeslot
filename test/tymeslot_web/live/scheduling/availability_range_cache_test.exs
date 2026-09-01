defmodule TymeslotWeb.Live.Scheduling.AvailabilityRangeCacheTest do
  @moduledoc """
  Pins what the availability layer asks the host's calendar provider for.

  The fetch behind `get_range_availability/7` is window-shaped, not
  month-shaped: it always returns `today .. today + advance_booking_days`,
  whatever date it is handed. Every rendered month therefore folds the
  *same* event list, and anything that walks the calendar — month arrows,
  Rhythm's week arrows crossing a boundary, and above all the
  next-available forward search, which re-enters this function once per
  hop — used to pay one full round trip to the provider per step.

  These tests count the round trips rather than the results, because the
  results were always correct. The cost was the defect.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :scheduling
  @moduletag :calendar

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks
  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    user = insert(:user)
    profile = insert(:profile, user: user, username: "rangecache", timezone: "America/New_York")

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 90,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    insert(:calendar_integration, user: user, is_active: true)

    %{user: user, profile: profile}
  end

  test "walking the calendar forward fetches the provider once, not once per month",
       %{user: user, profile: profile} do
    test_pid = self()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      send(test_pid, :provider_fetch)
      {:ok, []}
    end)

    # The four windows one page load can ask for: the month the booker lands
    # on plus the three hops `NextAvailable.@max_months_searched` allows.
    today = Date.utc_today()

    ranges =
      0..3
      |> Enum.map(&shift_month(today, &1))
      |> Enum.map(fn date -> Calculate.display_range(date.year, date.month) end)

    Enum.each(ranges, fn {start_date, end_date} ->
      assert {:ok, map} =
               AvailabilityHelpers.get_range_availability(
                 user.id,
                 start_date,
                 end_date,
                 "America/New_York",
                 profile,
                 context(profile),
                 30
               )

      assert map != %{}
    end)

    # Each window folds a different 42-day slice, so all four are computed;
    # what they must not do is ask the provider again for a list it already
    # holds. The ranges are distinct, so a display-range-keyed events fetch
    # misses on every one of them.
    assert provider_fetch_count() == 1
  end

  test "a failed fetch is not cached, so the next window retries it",
       %{user: user, profile: profile} do
    test_pid = self()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      send(test_pid, :provider_fetch)
      {:error, :all_calendars_unavailable}
    end)

    today = Date.utc_today()
    next = shift_month(today, 1)

    for date <- [today, next] do
      {start_date, end_date} = Calculate.display_range(date.year, date.month)

      assert {:error, :all_calendars_unavailable} =
               AvailabilityHelpers.get_range_availability(
                 user.id,
                 start_date,
                 end_date,
                 "America/New_York",
                 profile,
                 context(profile),
                 30
               )
    end

    # Caching the failure would pin an empty calendar for the whole TTL,
    # greying out every day on the booking page with no way to recover.
    assert provider_fetch_count() == 2
  end

  test "invalidating a user drops the cached events, not just the folded maps",
       %{user: user, profile: profile} do
    test_pid = self()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      send(test_pid, :provider_fetch)
      {:ok, []}
    end)

    today = Date.utc_today()
    {start_date, end_date} = Calculate.display_range(today.year, today.month)

    fetch = fn ->
      AvailabilityHelpers.get_range_availability(
        user.id,
        start_date,
        end_date,
        "America/New_York",
        profile,
        context(profile),
        30
      )
    end

    assert {:ok, _map} = fetch.()
    assert provider_fetch_count() == 1

    # A booking, a cancellation or a calendar sync calls this. If it cleared
    # only the folded maps the page would recompute them from an event list
    # up to the TTL old, which is the staleness the invalidation exists to
    # prevent.
    AvailabilityCache.invalidate_for_user(user.id)

    assert {:ok, _map} = fetch.()
    assert provider_fetch_count() == 1
  end

  defp context(profile) do
    %{
      demo_mode: false,
      organizer_profile: profile,
      meeting_type: nil,
      debug_calendar_module: nil
    }
  end

  # Drains and counts the fetch notifications the stub sent, so the count is
  # of round trips actually made rather than of anything the cache reports
  # about itself.
  defp provider_fetch_count(acc \\ 0) do
    receive do
      :provider_fetch -> provider_fetch_count(acc + 1)
    after
      0 -> acc
    end
  end

  defp shift_month(date, 0), do: date

  defp shift_month(date, months) do
    date
    |> Date.beginning_of_month()
    |> Date.add(32 * months)
    |> Date.beginning_of_month()
  end
end
