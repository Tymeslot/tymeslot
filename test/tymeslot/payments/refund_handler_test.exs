defmodule Tymeslot.Payments.Webhooks.RefundHandlerTest do
  use Tymeslot.DataCase, async: true
  @moduletag :payments

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

  describe "calculate_latest_refund_amount/1" do
    test "returns the amount of the most recently created refund, not the cumulative total" do
      charge = %{
        "amount_refunded" => 5000,
        "refunds" => %{
          "data" => [
            %{"amount" => 2000, "created" => 100},
            %{"amount" => 3000, "created" => 200}
          ]
        }
      }

      assert RefundHandler.calculate_latest_refund_amount(charge) == 3000
    end

    test "falls back to the cumulative total when no refunds list is present" do
      charge = %{"amount_refunded" => 5000}
      assert RefundHandler.calculate_latest_refund_amount(charge) == 5000
    end

    test "falls back to the cumulative total for an empty refunds list" do
      charge = %{"amount_refunded" => 0, "refunds" => %{"data" => []}}
      assert RefundHandler.calculate_latest_refund_amount(charge) == 0
    end

    test "handles atom keys" do
      charge = %{
        refunds: %{
          data: [
            %{amount: 1500, created: 10},
            %{amount: 2500, created: 20}
          ]
        }
      }

      assert RefundHandler.calculate_latest_refund_amount(charge) == 2500
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

  describe "refunds_current_subscription?/2" do
    @current %{stripe_subscription_id: "sub_current", status: "active"}

    test "a charge with no invoice paid for no subscription" do
      refute RefundHandler.refunds_current_subscription?(
               %{invoice_id: nil, subscription_id: nil},
               @current
             )
    end

    test "a charge for the current subscription refunds it" do
      assert RefundHandler.refunds_current_subscription?(
               %{invoice_id: "in_1", subscription_id: "sub_current"},
               @current
             )
    end

    # The subscription is read from Stripe when not recorded here, so an
    # invoice that names none billed none: the current subscription is not
    # assumed, since it may be one taken out after the refunded invoice.
    test "an invoice that billed no subscription does not refund the current one" do
      refute RefundHandler.refunds_current_subscription?(
               %{invoice_id: "in_1", subscription_id: nil},
               @current
             )
    end

    test "a charge for an earlier subscription does not refund the current one" do
      refute RefundHandler.refunds_current_subscription?(
               %{invoice_id: "in_1", subscription_id: "sub_earlier"},
               @current
             )
    end

    test "a subscription that has already ended is not refunded again" do
      for status <- ~w(canceled incomplete_expired) do
        refute RefundHandler.refunds_current_subscription?(
                 %{invoice_id: "in_1", subscription_id: "sub_current"},
                 %{@current | status: status}
               )
      end
    end

    # Only a live subscription has access a refund can end; an incomplete or
    # paused one never had it, so the email must not claim it was revoked.
    test "a subscription that is incomplete or paused is not refunded" do
      for status <- ~w(incomplete paused) do
        refute RefundHandler.refunds_current_subscription?(
                 %{invoice_id: "in_1", subscription_id: "sub_current"},
                 %{@current | status: status}
               )
      end
    end

    test "every live subscription status is refunded" do
      for status <- ~w(active trialing past_due unpaid) do
        assert RefundHandler.refunds_current_subscription?(
                 %{invoice_id: "in_1", subscription_id: "sub_current"},
                 %{@current | status: status}
               ),
               status
      end
    end
  end

  describe "handle/1 with a malformed event" do
    for type <- ["charge.refunded", "charge.refund.updated"] do
      test "#{type} without an object id is a permanent failure" do
        for object <- [%{"amount" => 1000}, %{}, nil] do
          event = %{"id" => "evt_bad", "type" => unquote(type), "data" => %{"object" => object}}
          assert {:error, :permanent, :missing_fields} = RefundHandler.handle(event)
        end

        assert {:error, :permanent, :missing_fields} =
                 RefundHandler.handle(%{"id" => "evt_bad", "type" => unquote(type)})
      end
    end

    test "an event type the handler does not own is a permanent failure" do
      event = %{
        "id" => "evt_other",
        "type" => "charge.succeeded",
        "data" => %{"object" => %{"id" => "ch_1"}}
      }

      assert {:error, :permanent, :missing_fields} = RefundHandler.handle(event)
    end
  end

  describe "extract_charge_currency/1" do
    test "extracts currency from string-keyed charge" do
      charge = %{"currency" => "usd", "amount" => 5000}
      assert RefundHandler.extract_charge_currency(charge) == "usd"
    end

    test "extracts currency from atom-keyed charge" do
      charge = %{currency: "gbp", amount: 5000}
      assert RefundHandler.extract_charge_currency(charge) == "gbp"
    end

    test "defaults to eur when currency key is absent" do
      charge = %{"amount" => 5000}
      assert RefundHandler.extract_charge_currency(charge) == "eur"
    end

    test "defaults to eur when currency value is nil" do
      assert RefundHandler.extract_charge_currency(%{"currency" => nil}) == "eur"
    end
  end
end
