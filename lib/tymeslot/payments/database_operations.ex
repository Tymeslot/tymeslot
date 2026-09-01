defmodule Tymeslot.Payments.DatabaseOperations do
  @moduledoc """
  Handles all database operations related to payments and transactions.
  This module coordinates between different database queries to ensure data consistency.
  """

  require Logger

  alias Tymeslot.Payments.{ErrorHandler, PaymentQueries, SubscriptionNotifications}
  alias Tymeslot.Payments.PaymentTransactionSchema, as: PaymentTransaction

  @type transaction :: PaymentTransaction.t()
  @type stripe_id :: String.t()
  @type event_type :: String.t()

  @doc """
  Creates a new payment transaction.
  """
  @spec create_payment_transaction(map()) :: {:ok, transaction()} | {:error, term()}
  def create_payment_transaction(attrs) do
    PaymentQueries.create_transaction(attrs)
  end

  @doc """
  Updates transaction status when payment fails.
  """
  @spec process_failed_payment(stripe_id()) ::
          {:ok, :payment_failed | :transaction_not_found} | {:error, any()}
  def process_failed_payment(stripe_id) do
    case PaymentQueries.get_transaction_by_stripe_id(stripe_id) do
      {:error, :transaction_not_found} ->
        Logger.info("Transaction not found for failed payment", stripe_id: stripe_id)
        {:ok, :transaction_not_found}

      {:ok, transaction} ->
        case PaymentQueries.update_transaction_status(transaction, "failed") do
          {:ok, updated_transaction} ->
            Logger.info("Payment updates processed", stripe_id: updated_transaction.stripe_id)

            {:ok, :payment_failed}

          {:error, changeset} ->
            handle_payment_processing_error(transaction, {:status_update_failed, changeset})
        end
    end
  end

  @doc """
  Updates a transaction when subscription checkout is completed.
  Links the transaction to the actual Stripe subscription ID.
  """
  @spec update_transaction_for_subscription(String.t(), String.t(), String.t(), map()) ::
          {:ok, transaction()} | {:error, term()}
  def update_transaction_for_subscription(checkout_session_id, subscription_id, status, metadata) do
    case PaymentQueries.get_transaction_by_stripe_id(checkout_session_id) do
      {:error, :transaction_not_found} ->
        Logger.error("Transaction not found for checkout session",
          checkout_session_id: checkout_session_id
        )

        {:error, :transaction_not_found}

      {:ok, transaction} ->
        attrs = %{
          status: status,
          subscription_id: subscription_id,
          metadata: Map.merge(transaction.metadata, metadata)
        }

        case PaymentQueries.update_transaction(transaction, attrs) do
          {:ok, updated_transaction} ->
            Logger.info("Subscription transaction updated",
              checkout_session_id: checkout_session_id,
              subscription_id: subscription_id
            )

            _result = SubscriptionNotifications.processed(updated_transaction)
            {:ok, updated_transaction}

          {:error, changeset} ->
            handle_subscription_processing_error(
              transaction,
              {:transaction_update_failed, changeset}
            )
        end
    end
  end

  @doc """
  Processes a failed subscription payment.
  """
  @spec process_subscription_failure(String.t(), map()) ::
          {:ok, :failure_processed} | {:error, term()}
  def process_subscription_failure(subscription_id, invoice_data) do
    Logger.warning("Processing subscription payment failure", subscription_id: subscription_id)

    case PaymentQueries.get_active_subscription_transaction_by_subscription_id(subscription_id) do
      {:error, :subscription_not_found} ->
        Logger.warning("No active subscription transaction found for failed payment",
          subscription_id: subscription_id
        )

        {:error, :subscription_not_found}

      {:ok, transaction} ->
        updated_metadata =
          Map.merge(transaction.metadata, %{
            failed_invoice_id: invoice_data["id"],
            failure_date: invoice_data["created"],
            failure_reason: invoice_data["billing_reason"],
            payment_attempt_count: invoice_data["attempt_count"]
          })

        attrs = %{
          metadata: updated_metadata,
          status: "pending_reconciliation"
        }

        case PaymentQueries.update_transaction(transaction, attrs) do
          {:ok, updated_transaction} ->
            {:ok, process_subscription_failure_updates(updated_transaction)}

          {:error, changeset} ->
            handle_subscription_processing_error(transaction, {:failure_update_failed, changeset})
        end
    end
  end

  # Error handling utility for future expansion of payment processing
  # capabilities. This function will be used when we implement more
  # sophisticated error handling strategies.
  @spec handle_payment_processing_error(transaction(), any()) ::
          {:error, binary()}
  defp handle_payment_processing_error(transaction, error) do
    error_message = "Payment processing failed: #{inspect(error)}"
    Logger.error(error_message)

    _result =
      ErrorHandler.handle_payment_error(
        transaction.stripe_id,
        error,
        transaction.user_id
      )

    {:error, error_message}
  end

  # Subscription-specific helper functions

  @spec process_subscription_failure_updates(transaction()) :: :failure_processed
  defp process_subscription_failure_updates(transaction) do
    Logger.warning("Subscription failure processed", stripe_id: transaction.stripe_id)

    :failure_processed
  end

  @spec handle_subscription_processing_error(transaction(), any()) ::
          {:error, binary()}
  defp handle_subscription_processing_error(transaction, error) do
    error_message = "Subscription processing failed: #{inspect(error)}"
    Logger.error(error_message)

    _result =
      ErrorHandler.handle_subscription_error(
        transaction.subscription_id || transaction.stripe_id,
        error,
        transaction.user_id
      )

    {:error, error_message}
  end
end
