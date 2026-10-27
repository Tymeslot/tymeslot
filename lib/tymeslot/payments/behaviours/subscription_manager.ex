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

  @doc """
  Checks if branding should be shown for a user.
  """
  @callback should_show_branding?(user_id :: integer()) :: boolean()

  @doc """
  The subscription recorded for a Stripe customer, or `nil`. Core reads only
  `user_id` from it, and hands it to the trial-ending email template.
  """
  @callback get_subscription_by_customer_id(stripe_customer_id :: String.t()) :: map() | nil

  @doc """
  The subscription recorded for a Stripe subscription id, or `nil`; as
  `c:get_subscription_by_customer_id/1`.
  """
  @callback get_subscription_by_subscription_id(stripe_subscription_id :: String.t()) ::
              map() | nil

  # Optional so a manager written before these lookups existed keeps working:
  # Core then finds no subscription record, as with no manager at all.
  @optional_callbacks get_subscription_by_customer_id: 1,
                      get_subscription_by_subscription_id: 1
end
