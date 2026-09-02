defmodule Tymeslot.Workers.EmailWorkerHandlers.DeliveryOutcomeTest do
  use ExUnit.Case, async: true

  @moduletag :emails

  alias Tymeslot.Workers.EmailWorkerHandlers.DeliveryOutcome

  describe "from_dual_send/4" do
    test "both delivered is :ok" do
      assert DeliveryOutcome.from_dual_send("test", [], {:ok, :sent}, {:ok, :sent}) == :ok
    end

    test "one genuinely delivered and the other failed discards, since a retry would duplicate the delivered one" do
      assert {:discard, _reason} =
               DeliveryOutcome.from_dual_send(
                 "test",
                 [],
                 {:ok, :sent},
                 {:error, "boom"}
               )
    end

    # Regression: a deliberately skipped recipient (e.g. the organiser on a
    # last-leaver seat cancellation) must not be counted as "already
    # delivered". Before this fix, `{:ok, :skipped}` matched the same
    # partial-success branch as a genuine send, so a transient failure on the
    # only recipient that was actually attempted was discarded instead of
    # retried.
    test "a skipped recipient paired with a failed one is not a partial success" do
      assert {:error, _reason} =
               DeliveryOutcome.from_dual_send(
                 "seat cancellation",
                 [],
                 {:ok, :skipped},
                 {:error, "transient failure"}
               )
    end

    test "a skipped recipient paired with a circuit-open failure still snoozes rather than discards" do
      assert {:error, :circuit_open} =
               DeliveryOutcome.from_dual_send(
                 "seat cancellation",
                 [],
                 {:ok, :skipped},
                 {:error, :circuit_open}
               )
    end
  end

  describe "from_error/2" do
    test "preserves :circuit_open instead of flattening it to the message" do
      assert DeliveryOutcome.from_error(:circuit_open, "Failed to send") ==
               {:error, :circuit_open}
    end

    test "preserves {:recipient_rejected, _} instead of flattening it to the message" do
      assert DeliveryOutcome.from_error({:recipient_rejected, "bounced"}, "Failed to send") ==
               {:error, {:recipient_rejected, "bounced"}}
    end

    test "any other reason falls back to the caller's message" do
      assert DeliveryOutcome.from_error(:some_other_reason, "Failed to send") ==
               {:error, "Failed to send"}
    end
  end
end
