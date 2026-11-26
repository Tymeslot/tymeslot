defmodule Tymeslot.StripeFixturesTest do
  use ExUnit.Case, async: true

  alias Tymeslot.StripeFixtures

  @moduletag :payments
  @moduletag :unit

  @dir Path.expand("../support/fixtures/stripe/api/2025-11-17.clover", __DIR__)

  @objects ~w(customer customer_deleted checkout_session_payment checkout_session_paid
              checkout_session_subscription checkout_session_expired subscription
              subscription_canceling subscription_canceled charge charge_with_refunds invoice
              invoice_payment refund refund_with_charge payment_intent_with_latest_charge
              dispute_lost account billing_portal_session)

  @errors ~w(resource_missing idempotency_error invalid_request_error charge_already_refunded
             card_error rate_limit api_error)

  defp names(glob) do
    @dir
    |> Path.join(glob)
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".json"))
    |> Enum.sort()
  end

  test "every fixture decodes and has a string id and object" do
    assert names("*.json") == Enum.sort(@objects)

    malformed =
      Enum.reject(@objects, fn name ->
        object = StripeFixtures.object(name)
        is_binary(object["id"]) and is_binary(object["object"])
      end)

    assert malformed == []
  end

  test "every error fixture carries an HTTP error status and Stripe's error type" do
    assert names("errors/*.json") == Enum.sort(@errors)

    malformed =
      Enum.reject(@errors, fn name ->
        {status, body} = StripeFixtures.error_body(name)
        status in 400..599 and is_binary(body["error"]["type"])
      end)

    assert malformed == []
  end

  test "overrides deep-merge" do
    refund =
      StripeFixtures.object("refund_with_charge", %{"charge" => %{"amount_refunded" => 700}})

    assert refund["charge"]["amount_refunded"] == 700
    assert refund["charge"]["id"] == "ch_test1"
    assert refund["charge"]["amount"] == StripeFixtures.object("charge")["amount"]
    assert refund["id"] == "re_test1"
  end

  test "an override that is not a map replaces the value, and nil sets the key to nil" do
    charge =
      StripeFixtures.object("charge", %{"metadata" => ["not", "a", "map"], "outcome" => nil})

    assert charge["metadata"] == ["not", "a", "map"]
    assert Map.has_key?(charge, "outcome")
    assert charge["outcome"] == nil
  end

  test "atom-keyed overrides raise" do
    error =
      assert_raise ArgumentError, fn ->
        StripeFixtures.object("charge", %{"outcome" => %{risk_level: "high"}})
      end

    assert error.message =~ ":risk_level"
  end

  test "list wraps objects in a Stripe list" do
    refund = StripeFixtures.object("refund")

    assert StripeFixtures.list([refund]) ==
             %{"object" => "list", "data" => [refund], "has_more" => false, "url" => "/v1/list"}

    assert %{"has_more" => true, "url" => "/v1/refunds"} =
             StripeFixtures.list([refund], has_more: true, url: "/v1/refunds")
  end

  test "error_body returns the status and Stripe's error body" do
    assert {404, %{"error" => %{"type" => "invalid_request_error", "code" => "resource_missing"}}} =
             StripeFixtures.error_body("resource_missing")

    assert {400, %{"error" => error}} =
             StripeFixtures.error_body("charge_already_refunded", %{"param" => "charge"})

    assert error["code"] == "charge_already_refunded"
    assert error["param"] == "charge"
  end

  test "without removes a nested key" do
    charge = StripeFixtures.object("charge")
    stripped = StripeFixtures.without(charge, ["outcome", "risk_score"])

    assert Map.has_key?(charge["outcome"], "risk_score")
    refute Map.has_key?(stripped["outcome"], "risk_score")
    assert stripped["outcome"]["risk_level"] == charge["outcome"]["risk_level"]
  end
end
