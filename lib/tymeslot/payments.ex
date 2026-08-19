defmodule Tymeslot.Payments do
  @moduledoc """
  Main entry point for payment operations.
  Provides a high-level interface for executing payment transactions.
  """

  require Logger

  alias Tymeslot.Payments.PaymentTransactionSchema, as: PaymentTransaction

  alias Tymeslot.Payments.{
    CustomerLookup,
    DatabaseOperations,
    PubSub,
    SubscriptionFlow,
    SubscriptionInvoice,
    SubscriptionInvoices,
    Subscriptions
  }

  @type transaction :: PaymentTransaction.t()
  @type stripe_id :: String.t()

  @doc """
  Processes a failed payment.

  ## Parameters
    * stripe_id - The Stripe session ID

  ## Returns
    * `{:ok, :payment_failed}` - If the payment failure is recorded successfully
    * `{:error, reason}` - If recording the payment failure fails
  """
  @spec process_failed_payment(stripe_id()) ::
          {:ok, :payment_failed | :transaction_not_found} | {:error, String.t()}
  def process_failed_payment(stripe_id) do
    Logger.info("Processing failed payment", stripe_id: stripe_id)
    DatabaseOperations.process_failed_payment(stripe_id)
  end

  @doc """
  Lists a user's platform subscription invoices, newest first.

  Each entry carries the Stripe-hosted invoice page and PDF, so callers can
  link a customer straight to their VAT document instead of routing them
  through the billing portal. Covers subscription invoices only — Connect
  direct-charge booking invoices are not captured; see
  `SubscriptionInvoiceSchema`.

  ## Parameters
    * user_id - The ID of the user whose invoices to list
    * limit - Maximum number of invoices to return (defaults to
      `SubscriptionInvoiceQueries`'s default when omitted)
  """
  @spec list_subscription_invoices(pos_integer()) :: [SubscriptionInvoice.t()]
  def list_subscription_invoices(user_id) do
    SubscriptionInvoices.list(user_id)
  end

  @spec list_subscription_invoices(pos_integer(), pos_integer()) :: [SubscriptionInvoice.t()]
  def list_subscription_invoices(user_id, limit) do
    SubscriptionInvoices.list(user_id, limit)
  end

  @doc """
  Initiates a subscription with the provided payment details.

  This function creates a Stripe checkout session for recurring payments.
  The calling application is responsible for plan validation and providing
  the concrete payment details (stripe_price_id, amount, product_identifier).

  ## Parameters
    * stripe_price_id - The Stripe price ID for the subscription
    * product_identifier - Generic identifier for what is being purchased (plan name, etc.)
    * amount - The subscription amount in cents (for transaction tracking)
    * user_id - The ID of the user purchasing the subscription
    * email - The user's email address
    * success_url - URL to redirect to after successful subscription (required)
    * cancel_url - URL to redirect to if subscription is cancelled (required)
    * metadata - Additional metadata for the subscription (app-specific data)

  ## Returns
    * `{:ok, %{checkout_url: url}}` - URL for the Stripe checkout session
    * `{:error, reason}` - If the subscription creation fails
  """
  @spec initiate_subscription(
          stripe_price_id :: String.t(),
          product_identifier :: String.t(),
          amount :: pos_integer(),
          user_id :: pos_integer(),
          email :: String.t(),
          urls :: %{success: String.t(), cancel: String.t()},
          metadata :: map()
        ) :: {:ok, %{checkout_url: String.t()}} | {:error, term()}
  def initiate_subscription(
        stripe_price_id,
        product_identifier,
        amount,
        user_id,
        email,
        urls,
        metadata \\ %{}
      ) do
    SubscriptionFlow.initiate_subscription(
      stripe_price_id,
      product_identifier,
      amount,
      user_id,
      email,
      urls,
      metadata
    )
  end

  @doc """
  Cancels an active subscription.

  ## Parameters
    * subscription_id - The Stripe subscription ID
    * user_id - The ID of the user canceling the subscription
    * opts - Options for cancellation (at_period_end: true/false)

  ## Returns
    * `{:ok, subscription}` - If the subscription is canceled successfully
    * `{:error, reason}` - If the cancellation fails
  """
  @spec cancel_subscription(String.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def cancel_subscription(subscription_id, user_id, opts \\ []) do
    Subscriptions.cancel_subscription(subscription_id, user_id, opts)
  end

  @doc """
  Updates a subscription to a new Stripe price.

  ## Parameters
    * subscription_id - The Stripe subscription ID
    * new_stripe_price_id - The new Stripe price ID
    * user_id - The ID of the user updating the subscription
    * metadata - Additional metadata

  ## Returns
    * `{:ok, subscription}` - If the subscription is updated successfully
    * `{:error, reason}` - If the update fails
  """
  @spec update_subscription(String.t(), String.t(), pos_integer(), map()) ::
          {:ok, map()} | {:error, term()}
  def update_subscription(
        subscription_id,
        new_stripe_price_id,
        user_id,
        metadata \\ %{}
      ) do
    Subscriptions.update_subscription(
      subscription_id,
      new_stripe_price_id,
      user_id,
      metadata
    )
  end

  @doc """
  Downgrades a subscription to a lower-tier plan at the end of the current period.

  No proration credits are given. The downgrade takes effect at period end.
  Primary use case: Annual subscription → Monthly subscription after year ends.

  ## Parameters
    * subscription_id - The Stripe subscription ID
    * new_stripe_price_id - The new (lower-tier) Stripe price ID
    * user_id - The ID of the user downgrading
    * metadata - Additional metadata (optional)

  ## Returns
    * `{:ok, subscription}` - If downgrade is scheduled successfully
    * `{:error, reason}` - If downgrade fails
  """
  @spec downgrade_subscription(String.t(), String.t(), pos_integer(), map()) ::
          {:ok, map()} | {:error, term()}
  def downgrade_subscription(
        subscription_id,
        new_stripe_price_id,
        user_id,
        metadata \\ %{}
      ) do
    Subscriptions.downgrade_subscription(
      subscription_id,
      new_stripe_price_id,
      user_id,
      metadata
    )
  end

  @doc """
  Reads a user id out of Stripe metadata, which carries it as a string.

  Returns `nil` for anything that is not a whole number, so a malformed or
  absent value never becomes a wrong user.
  """
  @spec parse_user_id(any()) :: integer() | nil
  defdelegate parse_user_id(id), to: CustomerLookup

  @doc """
  Records a checkout session's outcome against its transaction row, attaching
  the subscription it produced.
  """
  @spec update_transaction_for_subscription(String.t(), String.t(), String.t(), map()) ::
          {:ok, transaction()} | {:error, term()}
  defdelegate update_transaction_for_subscription(
                checkout_session_id,
                subscription_id,
                status,
                metadata
              ),
              to: DatabaseOperations

  @doc """
  Broadcasts a subscription lifecycle event to the payment-events topic.
  """
  @spec broadcast_subscription_event(%{
          required(:event) => atom(),
          required(:user_id) => integer(),
          optional(atom()) => term()
        }) :: :ok
  defdelegate broadcast_subscription_event(event_data), to: PubSub

  @doc """
  The PubSub server payment events are broadcast on, or `nil` when none is
  running.
  """
  @spec get_pubsub_server() :: module() | nil
  defdelegate get_pubsub_server, to: PubSub
end
