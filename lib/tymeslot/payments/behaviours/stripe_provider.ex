defmodule Tymeslot.Payments.Behaviours.StripeProvider do
  @moduledoc """
  Behaviour for Stripe payment operations.
  This allows us to mock Stripe calls during testing.
  """

  @callback create_customer(email_or_params :: String.t() | map()) ::
              {:ok, map()} | {:error, term()}

  @callback create_checkout_session_for_subscription(params :: map()) ::
              {:ok, map()} | {:error, term()}

  @callback create_billing_portal_session(customer_id :: String.t(), return_url :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback cancel_subscription(subscription_id :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback resume_subscription(subscription_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback delete_customer(customer_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback get_subscription(subscription_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback get_charge(charge_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback expire_checkout_session(session_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback list_subscriptions(params :: map()) ::
              {:ok, map()} | {:error, term()}

  @callback list_charges(params :: map()) ::
              {:ok, map()} | {:error, term()}

  @callback list_invoices(params :: map()) ::
              {:ok, map()} | {:error, term()}

  @callback get_invoice(invoice_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback list_invoice_payments(params :: map()) ::
              {:ok, map()} | {:error, term()}

  @callback update_subscription_automatic_tax(subscription_id :: String.t(), enabled :: boolean()) ::
              {:ok, map()} | {:error, term()}
end
