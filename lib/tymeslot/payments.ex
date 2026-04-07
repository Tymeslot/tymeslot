defmodule Tymeslot.Payments do
  @moduledoc """
  Main entry point for payment operations.
  Provides a high-level interface for executing payment transactions.
  """

  require Logger

  alias Tymeslot.Payments.PaymentTransactionSchema, as: PaymentTransaction

  alias Tymeslot.Payments.{
    Config,
    DatabaseOperations,
    Initiation,
    SubscriptionFlow,
    Subscriptions
  }

  @type transaction :: PaymentTransaction.t()
  @type stripe_id :: String.t()

  @completed_status "completed"

  @doc """
  Initiates a payment transaction for a user.

  This function only handles the payment processing and creates a transaction record.
  The calling application is responsible for any business logic such as updating
  user access levels, sending notifications, etc.

  ## Behavior for existing transactions
  - If a pending transaction exists for the user, it will be updated
    with the new amount, product_identifier, and metadata, and a new Stripe session
    will be created
  - If only completed or failed transactions exist, a new transaction will be created
  - This allows users to retry payments or change their selection without being blocked

  ## Parameters
    * amount - The amount to charge in cents
    * product_identifier - Generic identifier for what is being purchased (plan name, course ID, etc.)
    * user_id - The ID of the user making the payment
    * email - The user's email address
    * success_url - URL to redirect to after successful payment (required)
    * cancel_url - URL to redirect to if payment is cancelled (required)
    * metadata - Additional metadata for the transaction (app-specific data)

  ## Returns
    * `{:ok, session_url}` - URL for the Stripe checkout session
    * `{:error, reason}` - If the transaction creation fails
  """
  @spec initiate_payment(
          amount :: pos_integer(),
          product_identifier :: String.t(),
          user_id :: pos_integer(),
          email :: String.t(),
          success_url :: String.t(),
          cancel_url :: String.t(),
          metadata :: map()
        ) :: {:ok, String.t()} | {:error, term()}
  def initiate_payment(
        amount,
        product_identifier,
        user_id,
        email,
        success_url,
        cancel_url,
        metadata \\ %{}
      ) do
    Initiation.initiate_payment(
      amount,
      product_identifier,
      user_id,
      email,
      success_url,
      cancel_url,
      metadata
    )
  end

  @doc """
  Processes a successful payment.

  This function only updates the transaction status and tax information.
  The calling application should handle any business logic such as updating
  user permissions, sending confirmation emails, etc.

  ## Parameters
    * stripe_id - The Stripe session ID
    * tax_info - Tax information for the transaction
    * discount_amount - Any discount applied to the transaction (in cents)

  ## Returns
    * `{:ok, :payment_processed}` - If the payment is processed successfully
    * `{:error, reason}` - If the payment processing fails
  """
  @spec process_successful_payment(stripe_id(), map(), non_neg_integer()) ::
          {:ok, :payment_processed} | {:error, term()}
  def process_successful_payment(stripe_id, tax_info, discount_amount \\ 0) do
    Logger.info("Processing successful payment", stripe_id: stripe_id)

    case DatabaseOperations.get_transaction_by_stripe_id(stripe_id) do
      {:ok, %{status: @completed_status}} ->
        Logger.info("Payment already processed, skipping duplicate", stripe_id: stripe_id)
        {:ok, :payment_processed}

      {:ok, %{status: "pending"} = transaction} ->
        do_process_successful_payment(transaction, tax_info, discount_amount)

      {:ok, %{status: status}} ->
        Logger.warning("Received successful webhook for non-pending transaction",
          stripe_id: stripe_id,
          status: status
        )

        {:error, :invalid_transaction_state}

      {:error, :transaction_not_found} ->
        Logger.error("Transaction not found for successful payment", stripe_id: stripe_id)
        {:error, :transaction_not_found}
    end
  end

  defp do_process_successful_payment(transaction, tax_info, discount_amount) do
    with {:ok, _session} <- Config.stripe_provider().verify_session(transaction.stripe_id),
         {:ok, :payment_processed} <-
           DatabaseOperations.process_successful_payment(transaction, tax_info, discount_amount) do
      {:ok, :payment_processed}
    else
      {:error, reason} ->
        Logger.error("Failed to process payment", reason: inspect(reason))
        {:error, reason}
    end
  end

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
  Retrieves a transaction by its Stripe ID.

  ## Parameters
    * stripe_id - The Stripe session ID

  ## Returns
    * `{:ok, transaction}` - If the transaction is found
    * `{:error, :transaction_not_found}` - If no transaction is found
  """
  @spec get_transaction(stripe_id()) :: {:ok, transaction()} | {:error, :transaction_not_found}
  def get_transaction(stripe_id) do
    DatabaseOperations.get_transaction_by_stripe_id(stripe_id)
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
end
