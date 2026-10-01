defmodule Tymeslot.CalendarGrid.WriteQueueTest do
  @moduledoc """
  The grid's write queue as plain data: the references it gives writes,
  how it waits for an event another driver is writing, and what it can
  still save for a later sync when it will never be driven to its end. The ordering itself is covered end to end by
  `TymeslotWeb.Dashboard.CalendarGrid.EventWriteOrderTest` and
  `SeriesHoldLiveViewTest`.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.CalendarGrid.WriteHandOver
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

  describe "WriteHandOver.plans/1" do
    test "saves the edits waiting behind a running one, on top of its change" do
      {queue, _start} = WriteQueue.update(WriteQueue.new(), @event, %{summary: "Renamed"}, [])
      {queue, []} = WriteQueue.update(queue, @event, %{location: "Room 9"}, [])

      assert {[{base, [waiting]}], 0} = WriteHandOver.plans(queue)
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

      assert {[{_base, [waiting]}], 2} = WriteHandOver.plans(queue)
      assert waiting.changes == %{location: "Room 9"}
    end

    test "saves nothing behind a running video change" do
      {queue, _start} = WriteQueue.change_video(WriteQueue.new(), @event, 3)
      {queue, []} = WriteQueue.update(queue, @event, %{location: "Room 9"}, [])

      assert WriteHandOver.plans(queue) == {[], 1}
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

      assert WriteHandOver.plans(queue) == {[], 1}
    end

    test "has nothing to save for a running write alone" do
      {queue, _start} = WriteQueue.update(WriteQueue.new(), @event, %{summary: "Renamed"}, [])

      assert WriteHandOver.plans(queue) == {[], 0}
    end
  end

  describe "an event another driver is writing" do
    @key {7, "standup"}

    # A whole-series write needs an addressable series.
    @occurrence %{
      id: 2,
      calendar_integration_id: 7,
      uid: "weekly_20260601T090000",
      provider: "caldav",
      provider_event_id: "/cal/weekly.ics",
      recurrence_rule: "FREQ=WEEKLY",
      summary: "Weekly"
    }

    # Another occurrence of the same series.
    @other_occurrence %{@occurrence | id: 3, uid: "weekly_20260608T090000"}
    @other_key {7, "weekly_20260608T090000"}

    test "keeps its writes until every driver has released it, then makes them onto the event as they left it" do
      [one, two] = [spawn(fn -> :ok end), spawn(fn -> :ok end)]

      queue = WriteQueue.wait_elsewhere(WriteQueue.new(), [{one, [@key]}, {two, [@key]}])

      {queue, []} = WriteQueue.update(queue, @event, %{location: "Room 9"}, [])
      {queue, []} = WriteQueue.update(queue, @event, %{summary: "Renamed"}, [])

      assert {queue, []} = WriteQueue.resume(queue, {one, @key, {:ok, %{@event | location: "A"}}})
      refute WriteQueue.awaits?(queue, {:event_writes_released, {one, @key, :unknown}})

      left = %{@event | location: "B", summary: "Theirs"}

      assert {queue, [{:show, shown}, {:start, write, ^left}]} =
               WriteQueue.resume(queue, {two, @key, {:ok, left}})

      assert write.changes == %{location: "Room 9"}
      assert %{location: "Room 9", summary: "Renamed"} = shown

      # The second waits behind the first, as any second write does.
      assert {_queue, [{:start, next, %{location: "Room 9"}}]} =
               WriteQueue.settle(queue, write.ref, {:ok, %{left | location: "Room 9"}})

      assert next.changes == %{summary: "Renamed"}
    end

    # A guardian releases the events a lender killed outright still owed,
    # and may do so after the lender's own release.
    test "makes its writes once, however often the event is released" do
      queue = WriteQueue.wait_elsewhere(WriteQueue.new(), [{self(), [@key]}])
      {queue, []} = WriteQueue.update(queue, @event, %{location: "Room 9"}, [])

      assert {queue, [{:show, _shown}, {:start, write, _event}]} =
               WriteQueue.resume(queue, {self(), @key, {:ok, @event}})

      assert {^queue, []} = WriteQueue.resume(queue, {self(), @key, :unknown})

      assert {_queue, []} =
               WriteQueue.settle(queue, write.ref, {:ok, %{@event | location: "Room 9"}})
    end

    test "drops and counts its writes once the other driver changed the whole series" do
      queue = WriteQueue.wait_elsewhere(WriteQueue.new(), [{self(), [@key]}])
      {queue, []} = WriteQueue.update(queue, @event, %{location: "Room 9"}, [])

      assert {queue, [{:dropped, :series_write, 1}, :reload]} =
               WriteQueue.resume(queue, {self(), @key, :series_changed})

      refute WriteQueue.pending?(queue)
    end

    test "is not waited for when the queue is writing it itself" do
      {queue, [{:start, _write, _event}]} =
        WriteQueue.update(WriteQueue.new(), @event, %{summary: "Mine"}, [])

      queue = WriteQueue.wait_elsewhere(queue, [{self(), [@key]}])

      assert {_queue, []} = WriteQueue.update(queue, @event, %{location: "Room 9"}, [])
      refute WriteQueue.awaits?(queue, {:event_writes_released, {self(), @key, :unknown}})
    end

    # A driver that lends the event back may itself wait for this queue;
    # waiting for it too would leave each waiting for the other forever.
    test "is not waited for again from a driver lending it back to a queue already waiting for it" do
      [first, lent_back] = [spawn(fn -> :ok end), spawn(fn -> :ok end)]

      queue =
        WriteQueue.new()
        |> WriteQueue.wait_elsewhere([{first, [@key]}])
        |> WriteQueue.wait_elsewhere([{lent_back, [@key]}])

      {queue, []} = WriteQueue.update(queue, @event, %{location: "Room 9"}, [])

      assert {_queue, [{:show, _shown}, {:start, write, @event}]} =
               WriteQueue.resume(queue, {first, @key, {:ok, @event}})

      assert write.changes == %{location: "Room 9"}
    end

    test "is not waited for when the queue holds a write for it behind its series write" do
      {queue, [{:start, series_write, _event}]} =
        WriteQueue.update(WriteQueue.new(), @occurrence, %{summary: "All"},
          recurrence_scope: :all
        )

      {queue, []} = WriteQueue.update(queue, @other_occurrence, %{location: "Room 9"}, [])
      queue = WriteQueue.wait_elsewhere(queue, [{self(), [@other_key]}])

      # The series was not changed, so the held write starts.
      assert {_queue, [{:show, _reverted}, {:start, held, @other_occurrence}]} =
               WriteQueue.settle(queue, series_write.ref, :failed)

      assert held.changes == %{location: "Room 9"}
    end

    test "is left as the queue's last write left it once that write has answered" do
      {queue, [{:start, write, _event}]} =
        WriteQueue.update(WriteQueue.new(), @event, %{summary: "Renamed"}, [])

      accepted = %{@event | summary: "Renamed"}
      answer = {:event_update_result, {:ok, write: write.ref, updated_event: accepted}}
      failure = {:event_update_result, {:error, write: write.ref, retry: :not_queued}}

      assert WriteQueue.left_by(queue, @key, [answer]) == {:ok, accepted}
      assert WriteQueue.left_by(queue, @key, [failure]) == {:ok, @event}
      assert WriteQueue.pending_keys(queue) == [@key]
    end

    test "is left changed as a whole series after a write to the whole series" do
      {queue, [{:start, write, _event}]} =
        WriteQueue.update(WriteQueue.new(), @occurrence, %{summary: "All"},
          recurrence_scope: :all
        )

      answer = {:event_update_result, {:ok, write: write.ref, updated_event: @occurrence}}

      assert WriteQueue.left_by(queue, {7, @occurrence.uid}, [answer]) == :series_changed
    end

    test "is handed over, when the queue will never be driven, onto the event its kept writes were made against" do
      queue = WriteQueue.wait_elsewhere(WriteQueue.new(), [{self(), [@key]}])
      {queue, []} = WriteQueue.update(queue, @event, %{location: "Room 9"}, [])
      {queue, []} = WriteQueue.change_video(queue, %{@event | location: "Room 9"}, 3)

      assert {[{@event, [kept]}], 1} = WriteHandOver.plans(queue)
      assert kept.changes == %{location: "Room 9"}
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
