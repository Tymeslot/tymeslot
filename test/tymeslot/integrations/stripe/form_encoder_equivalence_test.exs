# Deleted in Task F1 together with the stripity_stripe dependency.
defmodule Tymeslot.Integrations.Stripe.FormEncoderEquivalenceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tymeslot.Integrations.Stripe.FormEncoder

  @moduletag :payments
  @moduletag :unit

  @corpus [
    %{
      "mode" => "payment",
      "line_items" => [
        %{
          "price_data" => %{
            "currency" => "eur",
            "unit_amount" => 2500,
            "product_data" => %{"name" => "Tea & cake"}
          },
          "quantity" => 1
        }
      ],
      "payment_intent_data" => %{
        "metadata" => %{"meeting_id" => "m1"},
        "application_fee_amount" => 125
      },
      "invoice_creation" => %{"enabled" => true},
      "customer_email" => "a@b.test",
      "client_reference_id" => "m1",
      "expires_at" => 1_800_000_000,
      "success_url" => "https://x.test/r?session_id={CHECKOUT_SESSION_ID}",
      "cancel_url" => "https://x.test/c",
      "locale" => "en"
    },
    %{
      charge: "ch_1",
      amount: 500,
      metadata: %{meeting_id: "m1"},
      expand: ["charge"],
      reason: nil,
      refund_application_fee: true
    },
    %{email: "a@b.test", metadata: %{"is_business" => "pending"}, address: %{country: "DE"}},
    %{cancel_at_period_end: true},
    %{automatic_tax: %{enabled: true}},
    %{
      customer: "cus_1",
      limit: 100,
      starting_after: nil,
      created: %{gte: 1_700_000_000},
      expand: ["data.refunds"]
    },
    %{payment: %{type: "payment_intent", payment_intent: "pi_1"}},
    %{customer: "cus_1", return_url: "https://x.test/dashboard"},
    %{
      mode: "subscription",
      line_items: [%{price: "price_1", quantity: 1}],
      subscription_data: %{metadata: %{user_id: "7"}},
      automatic_tax: %{enabled: true},
      customer_update: %{address: "auto", name: "auto"},
      success_url: "https://x.test/s?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: "https://x.test/c"
    },
    %{expand: [], metadata: %{}, a: 1},
    [a: [b: 1, c: ["x", "y"]], d: nil],
    %{}
  ]

  test "matches Stripe.URI.encode_query/1 for every shape Tymeslot sends" do
    mismatches =
      Enum.reject(@corpus, fn params ->
        FormEncoder.encode(params) == Stripe.URI.encode_query(params)
      end)

    assert mismatches == []
  end

  property "matches Stripe.URI.encode_query/1 for generated nested params" do
    check all(params <- map_of(key(), value(3), max_length: 4), max_runs: 300) do
      assert FormEncoder.encode(params) == Stripe.URI.encode_query(params)
    end
  end

  defp key, do: atom(:alphanumeric)

  defp leaf do
    one_of([string(:printable, max_length: 8), integer(), boolean(), constant(nil)])
  end

  defp value(0), do: leaf()

  defp value(depth) do
    one_of([
      leaf(),
      map_of(key(), value(depth - 1), max_length: 3),
      list_of(value(depth - 1), max_length: 3)
    ])
  end
end
