defmodule Tymeslot.Payments.Webhooks.RefundHandlerTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.Payments.Webhooks.RefundHandler

  describe "calculate_total_refunded/1" do
    test "uses amount_refunded when available" do
      charge = %{
        "amount_refunded" => 5000,
        "refunds" => %{
          "data" => [
            %{"amount" => 2000},
            %{"amount" => 3000}
          ]
        }
      }

      # Should use amount_refunded, not sum of refunds
      assert RefundHandler.calculate_total_refunded(charge) == 5000
    end

    test "sums individual refunds when amount_refunded not available" do
      charge = %{
        "refunds" => %{
          "data" => [
            %{"amount" => 2000},
            %{"amount" => 1500},
            %{"amount" => 500}
          ]
        }
      }

      assert RefundHandler.calculate_total_refunded(charge) == 4000
    end

    test "returns 0 for empty refunds" do
      charge = %{"refunds" => %{"data" => []}}
      assert RefundHandler.calculate_total_refunded(charge) == 0
    end

    test "handles missing refunds field" do
      charge = %{"amount" => 10_000}
      assert RefundHandler.calculate_total_refunded(charge) == 0
    end

    test "handles atom keys" do
      charge = %{
        amount_refunded: 3000,
        refunds: %{data: [%{amount: 3000}]}
      }

      assert RefundHandler.calculate_total_refunded(charge) == 3000
    end
  end

  describe "get_charge_amount/1" do
    test "extracts charge amount with string keys" do
      charge = %{"amount" => 10_000}
      assert RefundHandler.get_charge_amount(charge) == 10_000
    end

    test "extracts charge amount with atom keys" do
      charge = %{amount: 10_000}
      assert RefundHandler.get_charge_amount(charge) == 10_000
    end

    test "returns 0 for missing amount" do
      charge = %{}
      assert RefundHandler.get_charge_amount(charge) == 0
    end
  end

  describe "calculate_refund_percentage/2" do
    test "calculates percentage correctly" do
      assert RefundHandler.calculate_refund_percentage(5000, 10_000) == 50.0
      assert RefundHandler.calculate_refund_percentage(9000, 10_000) == 90.0
      assert RefundHandler.calculate_refund_percentage(9500, 10_000) == 95.0
    end

    test "rounds to 2 decimal places" do
      assert RefundHandler.calculate_refund_percentage(3333, 10_000) == 33.33
    end

    test "handles zero charge amount" do
      assert RefundHandler.calculate_refund_percentage(1000, 0) == 0.0
    end

    test "handles full refund" do
      assert RefundHandler.calculate_refund_percentage(10_000, 10_000) == 100.0
    end
  end

  describe "should_revoke_access?/2" do
    test "revokes when refund >= 90% threshold (default)" do
      # Exactly 90%
      assert RefundHandler.should_revoke_access?(9000, 10_000) == true
      # Above 90%
      assert RefundHandler.should_revoke_access?(9500, 10_000) == true
      # Full refund
      assert RefundHandler.should_revoke_access?(10_000, 10_000) == true
    end

    test "does not revoke when refund < 90% threshold" do
      # 89%
      assert RefundHandler.should_revoke_access?(8900, 10_000) == false
      # 50%
      assert RefundHandler.should_revoke_access?(5000, 10_000) == false
      # 10%
      assert RefundHandler.should_revoke_access?(1000, 10_000) == false
    end

    test "handles zero charge amount" do
      assert RefundHandler.should_revoke_access?(1000, 0) == false
    end

    test "handles zero refund amount" do
      assert RefundHandler.should_revoke_access?(0, 10_000) == false
    end
  end

  describe "refund_revocation_threshold_percent/0" do
    test "returns default threshold of 90%" do
      assert RefundHandler.refund_revocation_threshold_percent() == 90.0
    end
  end

  describe "validate/1" do
    test "accepts valid refund object with required fields" do
      refund = %{"id" => "re_test_123"}
      assert RefundHandler.validate(refund) == :ok
    end

    test "rejects refund object missing id" do
      refund = %{"amount" => 1000}
      assert {:error, :missing_fields, _message} = RefundHandler.validate(refund)
    end

    test "rejects non-map input" do
      assert {:error, :invalid_structure, _message} = RefundHandler.validate("not a map")
      assert {:error, :invalid_structure, _message} = RefundHandler.validate(nil)
    end
  end

  describe "can_handle?/1" do
    test "handles charge.refunded events" do
      assert RefundHandler.can_handle?("charge.refunded") == true
    end

    test "handles charge.refund.updated events" do
      assert RefundHandler.can_handle?("charge.refund.updated") == true
    end

    test "rejects other event types" do
      assert RefundHandler.can_handle?("charge.succeeded") == false
      assert RefundHandler.can_handle?("payment_intent.succeeded") == false
      assert RefundHandler.can_handle?("customer.created") == false
    end
  end
end
