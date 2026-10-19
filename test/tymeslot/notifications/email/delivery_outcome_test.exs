defmodule Tymeslot.Notifications.Email.DeliveryOutcomeTest do
  use ExUnit.Case, async: true

  @moduletag :emails

  alias Tymeslot.Notifications.Email.DeliveryOutcome

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
