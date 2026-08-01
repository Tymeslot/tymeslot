defmodule Tymeslot.Payments.Webhooks.IdempotencyCacheTest do
  use Tymeslot.DataCase, async: false
  @moduletag :payments

  alias Tymeslot.Payments.Webhooks.IdempotencyCache
  alias Tymeslot.Repo
  alias Tymeslot.Webhooks.WebhookEventSchema, as: WebhookEvent

  setup do
    # Clear cache before each test
    IdempotencyCache.clear_all()
    :ok
  end

  describe "check_idempotency/1" do
    test "returns :not_processed for new event" do
      event_id = generate_event_id()
      assert {:ok, :not_processed} = IdempotencyCache.check_idempotency(event_id)
    end

    test "returns :already_processed for previously processed event" do
      event_id = generate_event_id()

      # Mark as processed
      IdempotencyCache.mark_processed(event_id)

      # Check again
      assert {:ok, :already_processed} = IdempotencyCache.check_idempotency(event_id)
    end
  end

  describe "mark_processed/1" do
    test "marks an event as processed" do
      event_id = generate_event_id()

      # Initially not processed
      assert {:ok, :not_processed} = IdempotencyCache.check_idempotency(event_id)

      # Mark as processed
      assert :ok = IdempotencyCache.mark_processed(event_id)

      # Now should be processed
      assert {:ok, :already_processed} = IdempotencyCache.check_idempotency(event_id)
    end

    test "can mark multiple events independently" do
      {event_id1, event_id2} = generate_two_event_ids()

      # Mark first event
      IdempotencyCache.mark_processed(event_id1)

      # First is processed, second is not
      assert {:ok, :already_processed} = IdempotencyCache.check_idempotency(event_id1)
      assert {:ok, :not_processed} = IdempotencyCache.check_idempotency(event_id2)

      # Mark second event
      IdempotencyCache.mark_processed(event_id2)

      # Both are now processed
      assert {:ok, :already_processed} = IdempotencyCache.check_idempotency(event_id1)
      assert {:ok, :already_processed} = IdempotencyCache.check_idempotency(event_id2)
    end
  end

  describe "mark_processed/3 payload storage" do
    test "stores payload in database when provided" do
      event_id = generate_event_id()

      payload = %{
        "id" => event_id,
        "type" => "invoice.paid",
        "data" => %{"object" => %{"amount" => 1000}}
      }

      IdempotencyCache.mark_processed(event_id, "invoice.paid", payload)

      record = Repo.get_by!(WebhookEvent, stripe_event_id: event_id)
      assert record.payload == payload
    end

    test "stores nil payload when omitted" do
      event_id = generate_event_id()

      IdempotencyCache.mark_processed(event_id, "invoice.paid")

      record = Repo.get_by!(WebhookEvent, stripe_event_id: event_id)
      assert is_nil(record.payload)
    end
  end

  describe "reserve/1" do
    test "reserves a new event" do
      event_id = generate_event_id()
      assert {:ok, :reserved} = IdempotencyCache.reserve(event_id)
      assert {:ok, :in_progress} = IdempotencyCache.reserve(event_id)
    end

    test "release allows retries" do
      event_id = generate_event_id()

      assert {:ok, :reserved} = IdempotencyCache.reserve(event_id)
      assert :ok = IdempotencyCache.release(event_id)
      assert {:ok, :reserved} = IdempotencyCache.reserve(event_id)
    end

    test "a duplicate arriving after ETS is cleared (simulated restart) is still caught via the database tier" do
      event_id = generate_event_id()

      assert {:ok, :reserved} = IdempotencyCache.reserve(event_id)
      assert :ok = IdempotencyCache.mark_processed(event_id)

      # Simulate a node restart: the in-memory tier is gone, but the
      # database row (90-day retention) survives.
      :ets.delete_all_objects(:webhook_idempotency_cache)

      assert {:ok, :already_processed} = IdempotencyCache.reserve(event_id)
    end
  end

  describe "reserve/1 expiry-recovery" do
    test "replaces an expired-but-unclean entry and returns :reserved" do
      event_id = generate_event_id()
      # Insert a stale entry: expiry is 1 ms in the past so lookup_entry/1 returns :miss
      past_expiry = System.monotonic_time(:millisecond) - 1
      :ets.insert(:webhook_idempotency_cache, {event_id, :processing, past_expiry})

      # reserve/1 hits the :miss branch: deletes the stale row and re-inserts
      assert {:ok, :reserved} = IdempotencyCache.reserve(event_id)

      # The new entry is live — a second caller sees :in_progress
      assert {:ok, :in_progress} = IdempotencyCache.reserve(event_id)
    end
  end

  describe "reserve/1 concurrency" do
    # Stripe routinely retries webhooks; two parallel workers can land on
    # `reserve/1` for the same event_id before either has called
    # `mark_processed/3`. The ETS-backed `insert_new/2` must atomically
    # pick exactly one winner — otherwise the DB writes downstream would
    # double-apply the same event (duplicate subscription insert,
    # double-refund credit, etc.). Pin the contract directly.
    test "exactly one caller gets :reserved across concurrent callers" do
      event_id = generate_event_id()

      results =
        Tymeslot.TaskSupervisor
        |> Task.Supervisor.async_stream_nolink(
          1..25,
          fn _n -> IdempotencyCache.reserve(event_id) end,
          max_concurrency: 25,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      # Only one :reserved is possible because processing_ttl (10 min) >> test window;
      # the expired-entry recovery branch in reserve/1 cannot fire here.
      assert Enum.count(results, &match?({:ok, :reserved}, &1)) == 1,
             "expected exactly one :reserved across concurrent callers, got: #{inspect(results)}"

      losers = Enum.reject(results, &match?({:ok, :reserved}, &1))

      assert Enum.all?(losers, fn result ->
               match?({:ok, :in_progress}, result) or
                 match?({:ok, :already_processed}, result)
             end),
             "non-winners must resolve to :in_progress or :already_processed, got: #{inspect(losers)}"
    end
  end

  describe "clear_all/0" do
    test "clears all cached events" do
      {event_id1, event_id2} = generate_two_event_ids()

      # Mark events as processed
      IdempotencyCache.mark_processed(event_id1)
      IdempotencyCache.mark_processed(event_id2)

      # Verify they are processed
      assert {:ok, :already_processed} = IdempotencyCache.check_idempotency(event_id1)
      assert {:ok, :already_processed} = IdempotencyCache.check_idempotency(event_id2)

      # Clear all
      IdempotencyCache.clear_all()

      # Both should now be not processed
      assert {:ok, :not_processed} = IdempotencyCache.check_idempotency(event_id1)
      assert {:ok, :not_processed} = IdempotencyCache.check_idempotency(event_id2)
    end
  end

  defp generate_event_id do
    "evt_test_#{System.unique_integer([:positive])}"
  end

  defp generate_two_event_ids do
    {
      "evt_test_1_#{System.unique_integer([:positive])}",
      "evt_test_2_#{System.unique_integer([:positive])}"
    }
  end
end
