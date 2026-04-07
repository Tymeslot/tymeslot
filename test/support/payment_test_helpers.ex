defmodule Tymeslot.PaymentTestHelpers do
  @moduledoc """
  Test helpers for payment-related functionality.
  """

  alias Tymeslot.Payments.PaymentQueries
  alias Tymeslot.Payments.Webhooks.IdempotencyCache
  alias Tymeslot.Repo

  @doc """
  Creates a test payment transaction.
  """
  @spec create_test_transaction(map()) :: Tymeslot.Payments.PaymentTransactionSchema.t()
  def create_test_transaction(attrs \\ %{}) do
    defaults = %{
      user_id: attrs[:user_id] || raise("user_id is required"),
      amount: 500,
      status: "pending",
      stripe_id: "ch_test_#{System.unique_integer([:positive])}",
      stripe_customer_id: "cus_test_#{System.unique_integer([:positive])}",
      product_identifier: "pro_monthly",
      metadata: %{}
    }

    attrs = Map.merge(defaults, Enum.into(attrs, %{}))
    {:ok, transaction} = PaymentQueries.create_transaction(attrs)
    transaction
  end

  @doc """
  Creates a mock Stripe checkout session event.
  """
  @spec mock_stripe_checkout_session(map()) :: map()
  def mock_stripe_checkout_session(attrs \\ %{}) do
    session_id = attrs[:session_id] || "cs_test_#{System.unique_integer([:positive])}"
    customer_id = attrs[:customer_id] || "cus_test_#{System.unique_integer([:positive])}"

    %{
      "id" => session_id,
      "object" => "checkout.session",
      "customer" => customer_id,
      "client_reference_id" => attrs[:client_reference_id],
      "metadata" => attrs[:metadata] || %{},
      "payment_status" => attrs[:payment_status] || "paid",
      "status" => attrs[:status] || "complete",
      "mode" => attrs[:mode] || "payment",
      "amount_total" => attrs[:amount_total] || 500
    }
  end

  @doc """
  Creates a mock Stripe webhook event.
  """
  @spec mock_stripe_webhook_event(String.t(), map()) :: map()
  def mock_stripe_webhook_event(type, data) do
    %{
      "id" => "evt_test_#{System.unique_integer([:positive])}",
      "object" => "event",
      "type" => type,
      "data" => %{
        "object" => data
      },
      "created" => System.system_time(:second)
    }
  end

  @doc """
  Generates a valid Stripe webhook signature for testing.
  """
  @spec generate_stripe_signature(String.t(), String.t()) :: String.t()
  def generate_stripe_signature(payload, secret) do
    timestamp = System.system_time(:second)
    signed_payload = "#{timestamp}.#{payload}"
    signature = Base.encode16(:crypto.mac(:hmac, :sha256, secret, signed_payload), case: :lower)
    "t=#{timestamp},v1=#{signature}"
  end

  @doc """
  Clears all payment transactions from the database.
  Useful for test cleanup.
  """
  @spec clear_payment_transactions() :: {integer(), nil}
  def clear_payment_transactions do
    Repo.delete_all(Tymeslot.Payments.PaymentTransactionSchema)
  end

  @doc """
  Clears the webhook idempotency cache.
  """
  @spec clear_idempotency_cache() :: :ok
  def clear_idempotency_cache do
    IdempotencyCache.clear_all()
  end
end
