defmodule Tymeslot.Payments.Behaviours.StripeProvider do
  @moduledoc """
  Behaviour for Stripe payment operations.
  This allows us to mock Stripe calls during testing.
  """

  @callback create_customer(email_or_params :: String.t() | map()) ::
              {:ok, map()} | {:error, term()}

  @callback create_session(
              customer :: map(),
              amount :: pos_integer(),
              transaction :: map(),
              success_url :: String.t(),
              cancel_url :: String.t()
            ) ::
              {:ok, map()} | {:error, term()}

  @callback verify_session(session_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback create_checkout_session_for_subscription(params :: map()) ::
              {:ok, map()} | {:error, term()}

  @callback create_billing_portal_session(customer_id :: String.t(), return_url :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback cancel_subscription(subscription_id :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback update_subscription(subscription_id :: String.t(), new_price_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback update_subscription(
              subscription_id :: String.t(),
              new_price_id :: String.t(),
              opts :: map()
            ) ::
              {:ok, map()} | {:error, term()}

  @callback get_subscription(subscription_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback get_charge(charge_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback construct_webhook_event(
              payload :: binary(),
              signature :: String.t(),
              secret :: String.t()
            ) ::
              {:ok, map()} | {:error, term()}

  @callback expire_checkout_session(session_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback list_subscriptions(params :: map()) ::
              {:ok, map()} | {:error, term()}

  @callback webhook_secret() :: String.t() | nil
end
