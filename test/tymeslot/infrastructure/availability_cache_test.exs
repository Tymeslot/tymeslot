defmodule Tymeslot.Infrastructure.AvailabilityCacheTest do
  @moduledoc """
  `AvailabilityCache.invalidate_for_user/1` against range computations in
  flight.

  A range is folded from the host's cached booking-window events, so an
  invalidation has to leave no way for a range to be stored from the events
  it drops: neither one already running when it arrives, nor one starting
  while it is under way.

  The cache is the application's own process, so this module is not async,
  and the window between two steps of an invalidation is held open by
  suspending the processes involved rather than by sleeping.
  """

  use ExUnit.Case, async: false

  import Tymeslot.TestHelpers.Eventually

  alias Tymeslot.Infrastructure.AvailabilityCache

  @moduletag :availability

  setup do
    user_id = System.unique_integer([:positive])

    %{
      user_id: user_id,
      events_key: AvailabilityCache.booking_window_events_key(user_id),
      range_key:
        AvailabilityCache.availability_range_key(
          user_id,
          ~D[2026-11-02],
          ~D[2026-12-13],
          "Etc/UTC",
          30,
          nil,
          nil
        )
    }
  end

  test "a range computed while the user's entries are being dropped is not folded from the old events",
       context do
    %{user_id: user_id, events_key: events_key, range_key: range_key} = context
    AvailabilityCache.put(events_key, {:ok, [:old_event]})

    cache = Process.whereis(AvailabilityCache)
    :sys.suspend(cache)
    on_exit(fn -> if Process.alive?(cache), do: :sys.resume(cache) end)

    # The invalidation's first request is queued; holding the invalidating
    # process keeps any later one from being sent until the range is stored.
    invalidation = Task.async(fn -> AvailabilityCache.invalidate_for_user(user_id) end)

    eventually(fn ->
      assert Process.info(cache, :message_queue_len) == {:message_queue_len, 1}
    end)

    :erlang.suspend_process(invalidation.pid)
    :sys.resume(cache)

    assert range(range_key, events_key) == {:ok, [:new_event]}

    :erlang.resume_process(invalidation.pid)
    assert Task.await(invalidation) == :ok

    assert cached(range_key) == {:ok, [:new_event]}
  end

  # Guards an ordering rather than the invalidation itself: a range is
  # registered as in flight before it reads the events, so the invalidation
  # finds it and detaches it. Were the read to come first, the range would
  # be stored from the events the invalidation had just dropped.
  test "a range that read the events before the invalidation is not stored, because it registers before reading",
       context do
    %{user_id: user_id, events_key: events_key, range_key: range_key} = context
    AvailabilityCache.put(events_key, {:ok, [:old_event]})
    caller = self()

    # The range's computation is registered before it reads the events, and
    # parks once it has read them.
    in_flight =
      Task.async(fn ->
        AvailabilityCache.get_or_compute_events(range_key, fn ->
          events =
            AvailabilityCache.get_or_compute_events(events_key, fn -> flunk("refetched") end)

          send(caller, {:read, self(), events})

          receive do
            :finish -> events
          end
        end)
      end)

    assert_receive {:read, computing, {:ok, [:old_event]}}

    AvailabilityCache.invalidate_for_user(user_id)
    send(computing, :finish)

    # It still answers the caller that asked before the invalidation.
    assert Task.await(in_flight) == {:ok, [:old_event]}

    assert range(range_key, events_key) == {:ok, [:new_event]}
  end

  # A range folded from whatever the events entry holds, the way
  # `Offer.days_in_range/4` builds one, with the provider now answering
  # `:new_event`.
  defp range(range_key, events_key) do
    AvailabilityCache.get_or_compute_events(range_key, fn ->
      AvailabilityCache.get_or_compute_events(events_key, fn -> {:ok, [:new_event]} end)
    end)
  end

  defp cached(key) do
    AvailabilityCache.get_or_compute_events(key, fn -> {:ok, :not_cached} end)
  end
end
