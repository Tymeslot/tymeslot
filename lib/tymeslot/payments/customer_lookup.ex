defmodule Tymeslot.Payments.CustomerLookup do
  @moduledoc """
  Centralized customer lookup utilities for payment operations.

  Provides functions to parse and validate user IDs from various sources.

  Subscription lookups go through the configured subscription manager, so
  Core never reads another application's tables.
  """

  alias Tymeslot.Payments.Config
  alias Tymeslot.Payments.PaymentQueries

  @doc """
  Parses a user ID from metadata, handling both integer and string formats.

  Only accepts complete integer parses - partial matches like "42abc" are rejected.

  ## Examples

      iex> parse_user_id(42)
      42

      iex> parse_user_id("42")
      42

      iex> parse_user_id("42abc")
      nil

      iex> parse_user_id(nil)
      nil
  """
  @spec parse_user_id(any()) :: integer() | nil
  def parse_user_id(nil), do: nil
  def parse_user_id(id) when is_integer(id), do: id

  def parse_user_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> int_id
      _other -> nil
    end
  end

  def parse_user_id(_invalid), do: nil

  @doc """
  Gets the subscription recorded for a Stripe customer, from the configured
  subscription manager (`c:Tymeslot.Payments.Behaviours.SubscriptionManager.get_subscription_by_customer_id/1`).

  Returns `nil` when no subscription is found, when no subscription manager
  is configured (Core standalone, which tracks subscriptions on
  `payment_transactions` instead), or when the manager does not implement
  this optional callback.
  """
  @spec get_subscription_by_customer_id(String.t() | nil) :: map() | nil
  def get_subscription_by_customer_id(nil), do: nil

  def get_subscription_by_customer_id(stripe_customer_id) when is_binary(stripe_customer_id),
    do: from_manager(:get_subscription_by_customer_id, stripe_customer_id)

  @doc """
  Gets the subscription recorded for a Stripe subscription id; as
  `get_subscription_by_customer_id/1`.
  """
  @spec get_subscription_by_subscription_id(String.t() | nil) :: map() | nil
  def get_subscription_by_subscription_id(nil), do: nil

  def get_subscription_by_subscription_id(stripe_subscription_id)
      when is_binary(stripe_subscription_id),
      do: from_manager(:get_subscription_by_subscription_id, stripe_subscription_id)

  # The lookups are optional callbacks: a manager without them answers as no
  # manager at all.
  defp from_manager(lookup, id) do
    manager = Config.subscription_manager()

    if manager && Code.ensure_loaded?(manager) && function_exported?(manager, lookup, 1),
      do: apply(manager, lookup, [id]),
      else: nil
  end

  @doc """
  Resolves the user id owning a Stripe customer/subscription pair.

  Tries, in order:

    1. `metadata_user_id`, when given — the `user_id` Stripe echoes back on
       the invoice from the subscription's own metadata (set at checkout).
       It is authoritative and, unlike every step below, requires no row to
       exist locally yet, so it is the only signal available during the
       race between `checkout.session.completed` and the invoice webhooks
       for a subscription's very first invoice.
    2. The subscription manager's record by `stripe_subscription_id`, then by
       `stripe_customer_id` — the canonical customer/subscription -> user
       mapping when a subscription manager is configured, which is exact by
       construction.
    3. Only when none of the above resolves — normally because no
       subscription manager is configured (Core standalone, which tracks
       subscriptions on `payment_transactions` directly) — falls back to
       `payment_transactions`, matched the same way (subscription id, then
       customer id) and restricted to `completed` rows: a `pending` or
       `failed` transaction was never charged, so it is not an ownership
       signal.

  Returns `nil` when nothing resolves.
  """
  @spec find_user_id(%{
          optional(:metadata_user_id) => pos_integer() | nil,
          subscription_id: String.t() | nil,
          customer_id: String.t() | nil
        }) :: pos_integer() | nil
  def find_user_id(%{subscription_id: subscription_id, customer_id: customer_id} = params) do
    Map.get(params, :metadata_user_id) ||
      user_id_from_subscription(get_subscription_by_subscription_id(subscription_id)) ||
      user_id_from_subscription(get_subscription_by_customer_id(customer_id)) ||
      user_id_from_transaction(subscription_transaction(subscription_id)) ||
      user_id_from_transaction(customer_transaction(customer_id))
  end

  defp user_id_from_subscription(nil), do: nil
  defp user_id_from_subscription(%{user_id: user_id}), do: user_id

  defp user_id_from_transaction({:ok, transaction}), do: transaction.user_id
  defp user_id_from_transaction({:error, _reason}), do: nil

  defp subscription_transaction(nil), do: {:error, :no_subscription}

  defp subscription_transaction(subscription_id) do
    PaymentQueries.get_active_subscription_transaction_by_subscription_id(subscription_id)
  end

  defp customer_transaction(nil), do: {:error, :no_customer}

  defp customer_transaction(customer_id) do
    PaymentQueries.get_transaction_by_stripe_customer_id(customer_id)
  end
end
