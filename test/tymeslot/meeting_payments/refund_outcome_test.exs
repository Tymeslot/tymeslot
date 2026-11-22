defmodule Tymeslot.MeetingPayments.RefundOutcomeTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :payments

  alias Tymeslot.Integrations.Stripe.Error, as: StripeError
  alias Tymeslot.MeetingPayments.RefundOutcome

  describe "an answered refund" do
    for status <- ["succeeded", "pending", "requires_action"] do
      test "#{status} is money committed at Stripe" do
        refund = %{"id" => "re_1", "status" => unquote(status)}

        assert RefundOutcome.classify({:ok, refund}) == {:succeeded, refund}
      end
    end

    for status <- ["failed", "canceled"] do
      test "#{status} fails the refund with its status as the code" do
        assert RefundOutcome.classify({:ok, %{"id" => "re_1", "status" => unquote(status)}}) ==
                 {:failed, "refund_" <> unquote(status)}
      end
    end
  end

  describe "a Stripe error" do
    test "one a later attempt can get past is retried" do
      error = %StripeError{type: "api_connection_error", reason: :timeout}

      assert RefundOutcome.classify({:error, error}) == {:retry, error}
    end

    test "an idempotency error is retried, under the next attempt's key" do
      error = %StripeError{type: "idempotency_error", status: 400}

      assert RefundOutcome.classify({:error, error}) == {:retry, error}
    end

    test "a charge refunded already fails the refund" do
      error = %StripeError{
        type: "invalid_request_error",
        code: "charge_already_refunded",
        status: 400
      }

      assert RefundOutcome.classify({:error, error}) == {:failed, "charge_already_refunded"}
    end

    test "any other refusal fails the refund with its code" do
      error = %StripeError{type: "invalid_request_error", code: "amount_too_large", status: 400}

      assert RefundOutcome.classify({:error, error}) == {:failed, "amount_too_large"}
    end

    test "a refusal without a code fails the refund with its type" do
      error = %StripeError{type: "card_error", status: 402}

      assert RefundOutcome.classify({:error, error}) == {:failed, "card_error"}
    end
  end

  test "a missing API key is retried, as configuration may yet be fixed" do
    assert RefundOutcome.classify({:error, :missing_api_key}) == {:retry, :missing_api_key}
  end

  describe "a failed read of the charge's refunds" do
    test "one a later read can get past is retried" do
      error = %StripeError{type: "api_error", status: 500}

      assert RefundOutcome.classify_list_error(error) == {:retry, error}
    end

    test "one Stripe refuses for good fails the refund with its code" do
      error = %StripeError{type: "invalid_request_error", code: "account_invalid", status: 403}

      assert RefundOutcome.classify_list_error(error) == {:failed, "account_invalid"}
    end

    test "a missing API key is retried" do
      assert RefundOutcome.classify_list_error(:missing_api_key) == {:retry, :missing_api_key}
    end
  end
end
