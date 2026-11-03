defmodule Tymeslot.Availability.SlotGridOfferedStartsTest do
  @moduledoc """
  `SlotGrid` for a config carrying `:offered_starts` (a one-to-one type with
  fixed dates): the starts are exactly the listed instants, each under the
  booker's date it begins on, and the schedule's weekly hours play no part.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :unit

  alias Tymeslot.Availability.SlotGrid

  @day ~D[2030-03-12]

  defp starts(date, user_timezone, offered, extra \\ %{}) do
    {:ok, starts} =
      SlotGrid.starts_for_date(
        date,
        30,
        "Europe/London",
        user_timezone,
        Map.merge(%{schedule_id: nil, offered_starts: offered}, extra)
      )

    starts
  end

  test "returns the listed instants on the booker's date, sorted, in the booker's zone" do
    offered = [
      ~U[2030-03-12 15:00:00Z],
      ~U[2030-03-12 09:00:00Z],
      ~U[2030-03-13 09:00:00Z]
    ]

    assert [first, second] = starts(@day, "Etc/UTC", offered)
    assert first == ~U[2030-03-12 09:00:00Z]
    assert second == ~U[2030-03-12 15:00:00Z]
  end

  test "lists a start under the date it falls on in the booker's zone" do
    # 20:30 UTC on the 12th is 05:30 on the 13th in Tokyo, and 16:30 on the
    # 12th in New York.
    offered = [~U[2030-03-12 20:30:00Z]]

    assert starts(@day, "Asia/Tokyo", offered) == []
    assert [tokyo] = starts(Date.add(@day, 1), "Asia/Tokyo", offered)
    assert tokyo.time_zone == "Asia/Tokyo"
    assert DateTime.to_time(tokyo) == ~T[05:30:00]

    assert [new_york] = starts(@day, "America/New_York", offered)
    assert DateTime.to_time(new_york) == ~T[16:30:00]
  end

  test "ignores the weekly schedule, its slot interval and its breaks" do
    # A weekly schedule that is closed all week, stepped every two hours: the
    # listed start is offered all the same.
    config = %{weekly_schedule: [], overrides: [], time_off: [], slot_interval_minutes: 120}

    assert [only] = starts(@day, "Etc/UTC", [~U[2030-03-12 10:15:00Z]], config)
    assert only == ~U[2030-03-12 10:15:00Z]
  end

  test "an empty list offers nothing, rather than falling back to the schedule" do
    assert starts(@day, "Etc/UTC", []) == []
  end
end
