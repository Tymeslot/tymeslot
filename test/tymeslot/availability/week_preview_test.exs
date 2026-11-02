defmodule Tymeslot.Availability.WeekPreviewTest do
  @moduledoc """
  `Tymeslot.Availability.week_preview/2`: the host's next seven days, slots and
  busy blocks, in the host's timezone.

  The clock is frozen on the Sunday before a Monday at least two weeks out, so
  minimum notice never eats into the week and the test does not depend on when
  it runs.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability
  alias Tymeslot.Availability.WeekPreview
  alias Tymeslot.CalendarMock
  alias Tymeslot.Mocks.Calendar, as: CalendarFixtures
  alias Tymeslot.Test.ClockHelpers
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()

    monday =
      Date.utc_today() |> Date.add(14) |> Date.beginning_of_week(:monday) |> Date.add(7)

    ClockHelpers.freeze_clock(DateTime.new!(Date.add(monday, -1), ~T[00:00:00], "Etc/UTC"))
    %{monday: monday}
  end

  @office_hours %{is_available: true, start_time: ~T[09:00:00], end_time: ~T[17:00:00]}

  defp host(opts \\ []) do
    %{profile: profile} = create_bookable_profile(Keyword.put_new(opts, :hours, @office_hours))
    profile
  end

  defp stub_events(events) do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to -> {:ok, events} end)
  end

  test "counts free slots across the next seven days", %{monday: monday} do
    assert {:ok, %WeekPreview{} = preview} = Availability.week_preview(host(), today: monday)

    assert Enum.map(preview.days, & &1.date) == Enum.map(0..6, &Date.add(monday, &1))
    assert hd(hd(preview.days).slots) == "09:00"

    weekday_slots = preview.days |> Enum.take(5) |> Enum.map(&length(&1.slots))
    assert Enum.all?(weekday_slots, &(&1 == hd(weekday_slots)))
    assert hd(weekday_slots) > 0
    assert preview.days |> Enum.drop(5) |> Enum.all?(&(&1.slots == [] and &1.busy == []))
    assert preview.slot_count == 5 * hd(weekday_slots)
    assert preview.first_busy == nil
  end

  test "a busy event removes its slots and appears as a busy block", %{monday: monday} do
    tuesday = Date.add(monday, 1)

    stub_events([
      CalendarFixtures.event(
        start_time: DateTime.new!(tuesday, ~T[14:00:00], "Etc/UTC"),
        end_time: DateTime.new!(tuesday, ~T[15:00:00], "Etc/UTC")
      )
    ])

    assert {:ok, preview} = Availability.week_preview(host(), today: monday)

    [_monday, tuesday_preview | _rest] = preview.days
    refute "14:00" in tuesday_preview.slots
    refute "14:30" in tuesday_preview.slots
    assert "13:00" in tuesday_preview.slots
    assert tuesday_preview.busy == [{~T[14:00:00], ~T[15:00:00]}]
    assert preview.first_busy == %{date: tuesday, start: ~T[14:00:00]}
  end

  test "a busy block is clipped to the host's open hours", %{monday: monday} do
    stub_events([
      CalendarFixtures.event(
        start_time: DateTime.new!(monday, ~T[07:00:00], "Etc/UTC"),
        end_time: DateTime.new!(monday, ~T[10:00:00], "Etc/UTC")
      )
    ])

    assert {:ok, %{days: [first | _rest]}} = Availability.week_preview(host(), today: monday)
    assert first.busy == [{~T[09:00:00], ~T[10:00:00]}]
  end

  test "a calendar error returns calendar_unavailable", %{monday: monday} do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
      {:error, :timeout}
    end)

    assert {:error, :calendar_unavailable} = Availability.week_preview(host(), today: monday)
  end

  test "days are in the host's timezone" do
    # 23:00 UTC on a Sunday is already Monday noon in Auckland.
    sunday = Date.utc_today() |> Date.add(14) |> Date.beginning_of_week(:monday) |> Date.add(6)
    ClockHelpers.freeze_clock(DateTime.new!(sunday, ~T[23:00:00], "Etc/UTC"))

    profile = host(timezone: "Pacific/Auckland")

    assert {:ok, %{days: days}} = Availability.week_preview(profile)
    assert hd(days).date == Date.add(sunday, 1)
    assert length(days) == 7
  end

  test "the calendar is fetched once per call", %{monday: monday} do
    expect(CalendarMock, :get_events_for_range_fresh, 1, fn _user_id, _from, _to -> {:ok, []} end)

    assert {:ok, _preview} = Availability.week_preview(host(), today: monday)
  end
end
