defmodule Tymeslot.Polls.SlotHealthTest do
  use Tymeslot.DataCase, async: true

  @moduletag :unit
  @moduletag :polls

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Polls.SlotHealth
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  # Tomorrow at a fixed UTC wall-clock time, truncated to seconds.
  defp at(hour) do
    Date.utc_today()
    |> Date.add(1)
    |> DateTime.new!(Time.new!(hour, 0, 0), "Etc/UTC")
  end

  defp event(start_time, end_time, extra \\ %{}) do
    Map.merge(
      %{summary: "Busy", start_time: start_time, end_time: end_time},
      extra
    )
  end

  describe "check/1" do
    test "flags overlapping slots as :conflict and free slots as :ok" do
      poll = insert(:poll)

      conflicting =
        insert(:poll_time_slot,
          poll: poll,
          start_time: at(10),
          end_time: at(11),
          position: 0
        )

      free =
        insert(:poll_time_slot,
          poll: poll,
          start_time: at(14),
          end_time: at(15),
          position: 1
        )

      # A blocking event overlapping only the 10:00 slot.
      TestMocks.setup_calendar_mocks(
        events: [event(DateTime.add(at(10), 30, :minute), DateTime.add(at(11), 30, :minute))]
      )

      poll = %{poll | time_slots: [conflicting, free]}

      assert SlotHealth.check(poll) == %{conflicting.id => :conflict, free.id => :ok}
    end

    # The calendar cache hands an all-day event back with `Date` bounds, as
    # the booking path's conflict check receives it too. It blocks the whole
    # day in the host's time zone, and must not crash the comparison.
    test "an all-day busy event blocks the slots on its day" do
      poll = insert(:poll)
      tomorrow = Date.add(Date.utc_today(), 1)

      on_the_day =
        insert(:poll_time_slot, poll: poll, start_time: at(10), end_time: at(11), position: 0)

      next_day =
        insert(:poll_time_slot,
          poll: poll,
          start_time: DateTime.add(at(10), 1, :day),
          end_time: DateTime.add(at(11), 1, :day),
          position: 1
        )

      TestMocks.setup_calendar_mocks(
        events: [event(tomorrow, Date.add(tomorrow, 1), %{all_day: true})]
      )

      poll = %{poll | time_slots: [on_the_day, next_day]}
      assert SlotHealth.check(poll) == %{on_the_day.id => :conflict, next_day.id => :ok}
    end

    test "a cancelled event does not cause a conflict" do
      poll = insert(:poll)

      slot =
        insert(:poll_time_slot,
          poll: poll,
          start_time: at(10),
          end_time: at(11),
          position: 0
        )

      # Event overlaps the slot but is cancelled, so blocking?/1 filters it out.
      TestMocks.setup_calendar_mocks(events: [event(at(10), at(11), %{status: "cancelled"})])

      poll = %{poll | time_slots: [slot]}

      assert SlotHealth.check(poll) == %{slot.id => :ok}
    end

    test "a transparent (free) event does not cause a conflict" do
      poll = insert(:poll)

      slot =
        insert(:poll_time_slot,
          poll: poll,
          start_time: at(10),
          end_time: at(11),
          position: 0
        )

      TestMocks.setup_calendar_mocks(
        events: [event(at(10), at(11), %{transparency: "transparent"})]
      )

      poll = %{poll | time_slots: [slot]}

      assert SlotHealth.check(poll) == %{slot.id => :ok}
    end

    test "degrades to all-:ok when the calendar fetch fails" do
      poll = insert(:poll)

      slot_a =
        insert(:poll_time_slot,
          poll: poll,
          start_time: at(10),
          end_time: at(11),
          position: 0
        )

      slot_b =
        insert(:poll_time_slot,
          poll: poll,
          start_time: at(14),
          end_time: at(15),
          position: 1
        )

      TestMocks.setup_calendar_mocks(result: {:error, :all_calendars_unavailable})

      poll = %{poll | time_slots: [slot_a, slot_b]}

      assert SlotHealth.check(poll) == %{slot_a.id => :ok, slot_b.id => :ok}
    end

    test "returns an empty map for a poll with no slots" do
      assert SlotHealth.check(%{time_slots: []}) == %{}
    end
  end
end
