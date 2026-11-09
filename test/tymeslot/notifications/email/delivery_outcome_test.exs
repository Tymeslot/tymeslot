defmodule Tymeslot.Notifications.Email.DeliveryOutcomeTest do
  use ExUnit.Case, async: true

  @moduletag :emails

  alias Tymeslot.Notifications.Email.DeliveryOutcome

  describe "from_error/2" do
    test "preserves :circuit_open instead of flattening it to the message" do
      assert DeliveryOutcome.from_error(:circuit_open, "Failed to send") ==
               {:error, :circuit_open}
    end

    test "preserves sender contention for the worker's bounded snooze policy" do
      assert DeliveryOutcome.from_error(:rate_limited, "Failed to send") ==
               {:error, :rate_limited}
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

  test "rate limits survive mixed recipient outcomes and combined handler legs" do
    outcomes = [{:ok, :sent}, {:error, {:recipient_rejected, :gone}}, {:error, :rate_limited}]

    assert DeliveryOutcome.first_actionable(outcomes) == :rate_limited
    assert DeliveryOutcome.from_results("cancellation", [], outcomes) == {:error, :rate_limited}

    assert DeliveryOutcome.combine("cancellation", [], [:ok, {:error, :rate_limited}]) ==
             {:error, :rate_limited}
  end

  test "an open circuit takes precedence over connection contention" do
    assert DeliveryOutcome.first_actionable([{:error, :rate_limited}, {:error, :circuit_open}]) ==
             :circuit_open
  end
end
