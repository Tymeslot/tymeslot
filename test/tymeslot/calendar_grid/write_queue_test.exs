defmodule Tymeslot.CalendarGrid.WriteQueueTest do
  @moduledoc """
  The grid's write queue as plain data: the references it gives writes, and
  what it can still save for a later sync when it will never be driven to
  its end. The ordering itself is covered end to end by
  `TymeslotWeb.Dashboard.CalendarGrid.EventWriteOrderTest` and
  `SeriesHoldLiveViewTest`.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.CalendarGrid.WriteQueue

  # Outside any series, so no series is held.
  @event %{
    id: 1,
    calendar_integration_id: 7,
    uid: "standup",
    summary: "Standup",
    location: "Room 1"
  }

  describe "references" do
    # A grid mounted again starts a new queue while answers for the old one
    # may still arrive; one of them must never settle a new write.
    test "two queues never give a write the same reference" do
      {_first, [{:start, old_write, _event}]} =
        WriteQueue.update(WriteQueue.new(), @event, %{summary: "Old"}, [])

      {queue, [{:start, new_write, _event}]} =
        WriteQueue.update(WriteQueue.new(), @event, %{summary: "New"}, [])

      refute old_write.ref == new_write.ref
      assert WriteQueue.settle(queue, old_write.ref, :failed) == {queue, []}
    end

    test "rise with every write a queue takes" do
      {queue, [{:start, first, _event}]} =
        WriteQueue.update(WriteQueue.new(), @event, %{summary: "A"}, [])

      {queue, []} = WriteQueue.update(queue, @event, %{summary: "B"}, [])
      {_queue, [{:start, second, _event}]} = WriteQueue.settle(queue, first.ref, {:ok, @event})

      {key, first_seq} = first.ref
      assert {^key, second_seq} = second.ref
      assert second_seq > first_seq
    end
  end

  describe "hand_over/1" do
    test "saves the edits waiting behind a running one, on top of its change" do
      {queue, _start} = WriteQueue.update(WriteQueue.new(), @event, %{summary: "Renamed"}, [])
      {queue, []} = WriteQueue.update(queue, @event, %{location: "Room 9"}, [])

      assert {[{base, [waiting]}], 0} = WriteQueue.hand_over(queue)
      assert %{summary: "Renamed", location: "Room 1"} = base
      assert waiting.changes == %{location: "Room 9"}
    end

    # What a video change writes is only known once the video provider has
    # answered, so neither it nor what waits behind it can be saved.
    test "stops at a video change, and counts it and what follows as lost" do
      {queue, _start} = WriteQueue.update(WriteQueue.new(), @event, %{summary: "Renamed"}, [])
      {queue, []} = WriteQueue.update(queue, @event, %{location: "Room 9"}, [])
      {queue, []} = WriteQueue.change_video(queue, @event, 3)
      {queue, []} = WriteQueue.update(queue, @event, %{location: "Room 10"}, [])

      assert {[{_base, [waiting]}], 2} = WriteQueue.hand_over(queue)
      assert waiting.changes == %{location: "Room 9"}
    end

    test "saves nothing behind a running video change" do
      {queue, _start} = WriteQueue.change_video(WriteQueue.new(), @event, 3)
      {queue, []} = WriteQueue.update(queue, @event, %{location: "Room 9"}, [])

      assert WriteQueue.hand_over(queue) == {[], 1}
    end

    # Whether a held edit may still be made depends on how the series write
    # or move it waits for ends.
    test "counts the edits held while a series moves as lost" do
      occurrence = %{
        id: 2,
        calendar_integration_id: 7,
        uid: "weekly_20260601T090000",
        provider: "caldav",
        provider_event_id: "/cal/weekly.ics",
        recurrence_rule: "FREQ=WEEKLY"
      }

      queue = WriteQueue.series_moving(WriteQueue.new(), occurrence)

      {queue, []} =
        WriteQueue.update(queue, %{occurrence | id: 3, uid: "weekly_x"}, %{summary: "A"}, [])

      assert WriteQueue.hand_over(queue) == {[], 1}
    end

    test "has nothing to save for a running write alone" do
      {queue, _start} = WriteQueue.update(WriteQueue.new(), @event, %{summary: "Renamed"}, [])

      assert WriteQueue.hand_over(queue) == {[], 0}
    end
  end

  describe "merge/2" do
    # Two occurrences of one series, which the queue holds by its master.
    @occurrence %{
      id: 2,
      calendar_integration_id: 7,
      uid: "weekly_1",
      provider: "google",
      recurring_event_id: "weekly",
      summary: "Weekly"
    }
    @other_occurrence %{@occurrence | id: 3, uid: "weekly_2"}

    test "joins queues writing different events, each still waiting on its own write" do
      {queue, [{:start, mine, _event}]} =
        WriteQueue.update(WriteQueue.new(), @event, %{summary: "Mine"}, [])

      {other, [{:start, theirs, _event}]} =
        WriteQueue.update(WriteQueue.new(), @occurrence, %{summary: "Theirs"}, [])

      {other, []} = WriteQueue.update(other, @occurrence, %{location: "Room 9"}, [])

      assert {:ok, merged} = WriteQueue.merge(queue, other)
      assert WriteQueue.pending_count(merged) == 3

      assert {_merged, [{:start, waiting, %{summary: "Theirs"}}]} =
               WriteQueue.settle(merged, theirs.ref, {:ok, %{@occurrence | summary: "Theirs"}})

      assert waiting.changes == %{location: "Room 9"}
      assert {_merged, []} = WriteQueue.settle(merged, mine.ref, {:ok, @event})
    end

    test "refuses queues that both write one event" do
      {queue, _start} = WriteQueue.update(WriteQueue.new(), @event, %{summary: "Mine"}, [])
      {other, _start} = WriteQueue.update(WriteQueue.new(), @event, %{summary: "Theirs"}, [])

      assert WriteQueue.merge(queue, other) == :conflict
    end

    test "refuses a queue writing an occurrence of a series the other is moving" do
      {queue, _start} =
        WriteQueue.update(WriteQueue.new(), @other_occurrence, %{summary: "Mine"}, [])

      moving = WriteQueue.series_moving(WriteQueue.new(), @occurrence)

      assert WriteQueue.merge(queue, moving) == :conflict
      assert WriteQueue.merge(moving, queue) == :conflict
    end
  end

  describe "running/1" do
    test "keeps the write in flight, and nothing waiting behind it" do
      {queue, [{:start, write, _event}]} =
        WriteQueue.update(WriteQueue.new(), @event, %{summary: "Renamed"}, [])

      {queue, []} = WriteQueue.update(queue, @event, %{location: "Room 9"}, [])
      running = WriteQueue.running(queue)

      assert WriteQueue.pending_count(running) == 1
      assert {drained, []} = WriteQueue.settle(running, write.ref, {:ok, @event})
      refute WriteQueue.pending?(drained)
    end
  end

  describe "telling the attendees" do
    @notify %{original: @event, saved_message: "Saved"}

    test "an accepted write made with notify asks for it, in the scope it was written in" do
      updated = %{@event | summary: "Renamed"}

      {queue, [{:start, write, _event}]} =
        WriteQueue.update(WriteQueue.new(), @event, %{summary: "Renamed"}, [], @notify)

      assert {_queue, [{:notify, @notify, ^updated, :this_only}]} =
               WriteQueue.settle(queue, write.ref, {:ok, updated})
    end

    test "a failed write, or one made without notify, asks nobody" do
      {queue, [{:start, write, _event}]} =
        WriteQueue.update(WriteQueue.new(), @event, %{summary: "Renamed"}, [], @notify)

      assert {_queue, effects} = WriteQueue.settle(queue, write.ref, :failed)
      refute Enum.any?(effects, &match?({:notify, _, _, _}, &1))

      {queue, [{:start, plain, _event}]} =
        WriteQueue.update(WriteQueue.new(), @event, %{summary: "Renamed"}, [])

      assert {_queue, []} = WriteQueue.settle(queue, plain.ref, {:ok, @event})
    end
  end
end
