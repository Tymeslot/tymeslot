defmodule Tymeslot.Payments.Behaviours.SubscriptionManager do
  @moduledoc """
  Behaviour for subscription management.
  Allows CORE to remain blind to SaaS implementations while supporting
  subscription features when they are enabled.
  """

  @callback create_subscription_checkout(
              stripe_price_id :: String.t(),
              product_identifier :: String.t(),
              amount :: integer(),
              user_id :: integer(),
              email :: String.t(),
              urls :: %{success: String.t(), cancel: String.t()},
              metadata :: map()
            ) :: {:ok, map()} | {:error, term()}

  @callback handle_checkout_completed(checkout_session :: map()) ::
              {:ok, struct()} | {:error, term()}

  @callback cancel_subscription(
              subscription_id :: String.t(),
              user_id :: integer(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}

  @callback update_subscription(
              subscription_id :: String.t(),
              new_stripe_price_id :: String.t(),
              user_id :: integer(),
              metadata :: map()
            ) :: {:ok, map()} | {:error, term()}

  @callback update_subscription_status(
              stripe_customer_id :: String.t(),
              status :: String.t(),
              canceled_at :: DateTime.t() | nil
            ) :: {:ok, struct()} | {:error, term()}

  @doc """
  Checks if branding should be shown for a user.
  """
  @callback should_show_branding?(user_id :: integer()) :: boolean()
end
