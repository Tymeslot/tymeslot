# Deleted in Task F1 together with the stripity_stripe dependency.
defmodule Tymeslot.Integrations.Stripe.FormEncoderEquivalenceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tymeslot.Integrations.Stripe.FormEncoder

  @moduletag :payments
  @moduletag :unit

  @terms "I ask for Tymeslot Pro to start straight away. If I withdraw within 14 days, I pay for the days I used, as set out in the [Terms](https://tymeslot.app/legal/terms-and-conditions)."
  @terms_de "Ich bitte darum, dass Tymeslot Pro sofort beginnt. Bei Widerruf innerhalb von 14 Tagen zahle ich für die genutzten Tage, wie in den [AGB](https://tymeslot.app/legal/terms-and-conditions) beschrieben."

  @subscription_checkout %{
    customer: "cus_123",
    line_items: [%{price: "price_123", quantity: 1}],
    mode: "subscription",
    success_url: "https://tymeslot.app/dashboard/subscription?session_id={CHECKOUT_SESSION_ID}",
    cancel_url: "https://tymeslot.app/dashboard/subscription",
    metadata:
      Map.merge(%{"checkout_request_id" => "req-1", "billing_interval" => "month"}, %{
        product_identifier: "pro",
        user_id: "7"
      }),
    allow_promotion_codes: true,
    billing_address_collection: "auto",
    tax_id_collection: %{enabled: true},
    automatic_tax: %{enabled: true},
    customer_update: %{address: "auto", name: "auto", shipping: "auto"},
    subscription_data: %{
      metadata: %{
        "user_id" => "7",
        "product_identifier" => "pro",
        "checkout_request_id" => "req-1",
        "billing_interval" => "month"
      },
      trial_period_days: 14,
      trial_settings: %{end_behavior: %{missing_payment_method: "cancel"}}
    },
    consent_collection: %{terms_of_service: "required"},
    custom_text: %{terms_of_service_acceptance: %{message: @terms}}
  }

  @corpus [
    %{
      mode: "payment",
      line_items: [
        %{
          price_data: %{
            currency: "eur",
            unit_amount: 2500,
            product_data: %{name: "Tea & cake, 2 sessions"}
          },
          quantity: 2
        }
      ],
      payment_intent_data: %{
        metadata: Map.put(%{meeting_id: "m1", attendee_email: "a@b.test"}, :host_user_id, 7),
        application_fee_amount: 125
      },
      invoice_creation: %{enabled: true},
      customer_email: "a@b.test",
      client_reference_id: "ref-1",
      expires_at: 1_800_000_000,
      success_url: "https://x.test/r?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: "https://x.test/c",
      locale: "en"
    },
    @subscription_checkout,
    put_in(
      @subscription_checkout,
      [:custom_text, :terms_of_service_acceptance, :message],
      @terms_de
    ),
    Map.merge(
      %{email: "a@b.test", metadata: %{"is_business" => "pending"}},
      Map.take(
        %{
          name: "Ada Müller",
          phone: "+49 30 1234567",
          address: %{
            line1: "Hauptstr. 1",
            line2: "Hinterhaus",
            city: "Berlin",
            state: "BE",
            postal_code: "10115",
            country: "DE"
          },
          extra: "dropped"
        },
        [:name, :phone, :address]
      )
    ),
    %{
      charge: "ch_1",
      amount: 500,
      metadata: %{meeting_id: "m1"},
      expand: ["charge"],
      reason: nil,
      refund_application_fee: true
    },
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
