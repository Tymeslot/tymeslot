defmodule Tymeslot.Payments.Webhooks.IdempotencyCacheTest do
  @moduletag :payments
  use Tymeslot.DataCase, async: false

  alias Tymeslot.Payments.Webhooks.IdempotencyCache

  setup do
  @moduletag :payments
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
