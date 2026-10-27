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

    test "an all-day event blocks the host's local day" do
      profile = insert(:profile, timezone: "Australia/Sydney")
      poll = insert(:poll, user: profile.user)
      holiday = Date.add(Date.utc_today(), 1)

      # Midday UTC on the holiday's date is the evening of the host's day.
      inside =
        insert(:poll_time_slot,
          poll: poll,
          start_time: DateTime.new!(holiday, ~T[02:00:00], "Etc/UTC"),
          end_time: DateTime.new!(holiday, ~T[03:00:00], "Etc/UTC"),
          position: 0
        )

      # 22:00 UTC on the holiday's date is the next morning in Sydney.
      after_holiday =
        insert(:poll_time_slot,
          poll: poll,
          start_time: DateTime.new!(holiday, ~T[22:00:00], "Etc/UTC"),
          end_time: DateTime.new!(holiday, ~T[23:00:00], "Etc/UTC"),
          position: 1
        )

      TestMocks.setup_calendar_mocks(
        events: [event(holiday, Date.add(holiday, 1), %{all_day: true})]
      )

      poll = %{poll | time_slots: [inside, after_holiday]}

      assert SlotHealth.check(poll) == %{inside.id => :conflict, after_holiday.id => :ok}
    end

    test "an all-day event outside the slots' UTC days still blocks the host's local day" do
      profile = insert(:profile, timezone: "Pacific/Honolulu")
      poll = insert(:poll, user: profile.user)
      holiday = Date.add(Date.utc_today(), 1)
      next_utc_day = Date.add(holiday, 1)

      # 15:00 on the holiday in Honolulu is 01:00 UTC the next day.
      slot =
        insert(:poll_time_slot,
          poll: poll,
          start_time: DateTime.new!(next_utc_day, ~T[01:00:00], "Etc/UTC"),
          end_time: DateTime.new!(next_utc_day, ~T[02:00:00], "Etc/UTC"),
          position: 0
        )

      # Like a provider, the stub answers only for the days it is asked about,
      # reading the event's dates as UTC days.
      stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, from, to ->
        if Date.compare(from, holiday) != :gt and Date.compare(to, holiday) != :lt do
          {:ok, [event(holiday, Date.add(holiday, 1), %{all_day: true})]}
        else
          {:ok, []}
        end
      end)

      assert SlotHealth.check(%{poll | time_slots: [slot]}) == %{slot.id => :conflict}
    end

    test "returns an empty map for a poll with no slots" do
      assert SlotHealth.check(%{time_slots: []}) == %{}
    end
  end
end
