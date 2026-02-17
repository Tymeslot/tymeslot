defmodule Tymeslot.Payments.ErrorConventions do
  @moduledoc """
  Defines standardized error handling conventions for the payment system.

  This module documents the error handling patterns used across all payment
  modules to ensure consistency and predictability.

  ## Error Return Patterns

  The payment system uses the following standardized error patterns:

  ### 1. Simple Atomic Errors

  For simple, well-defined error cases, return `{:error, atom()}`:

      {:error, :not_found}
      {:error, :unauthorized}
      {:error, :invalid_amount}
      {:error, :rate_limited}
      {:error, :subscription_already_exists}

  **Use when:**
  - The error reason is simple and self-explanatory
  - No additional context is needed
  - The caller can handle the error based on the atom alone

  **Examples:**
  - `Tymeslot.Payments.cancel_subscription/3`
  - `Tymeslot.Payments.MetadataSanitizer.sanitize/2`

  ### 2. Structured Error Maps

  For errors that need additional context, return `{:error, map()}`:

      {:error, %{
        reason: :payment_failed,
        message: "Payment declined by card issuer",
        stripe_code: "card_declined",
        user_id: 123
      }}

  **Use when:**
  - You need to provide additional context to the caller
  - The error includes multiple pieces of information
  - You want to enable better error tracking and debugging

  **Examples:**
  - Future webhook processing errors
  - Complex validation failures

  ### 3. Ecto Changesets

  For database validation errors, return `{:error, %Ecto.Changeset{}}`:

      {:error, %Ecto.Changeset{
        errors: [amount: {"must be greater than 0", [validation: :number]}]
      }}

  **Use when:**
  - Creating or updating database records
  - Multiple field validations may fail
  - Caller needs detailed field-level error information

  **Examples:**
  - `Tymeslot.DatabaseQueries.PaymentQueries.create_transaction/1`
  - `Tymeslot.DatabaseQueries.PaymentQueries.update_transaction/2`

  ### 4. Exception-Based Errors (Avoid)

  **DO NOT** use exception-based error handling for expected failures:

      # ❌ BAD
      raise ArgumentError, "Invalid amount"

      # ✅ GOOD
      {:error, :invalid_amount}

  **Only use exceptions for:**
  - Programming errors (bugs)
  - Unexpected system failures
  - Configuration errors at startup

  ## Error Atoms Reference

  ### Authentication & Authorization
  - `:unauthorized` - User does not have permission
  - `:subscription_not_found` - Subscription does not exist
  - `:user_not_found` - User does not exist

  ### Validation Errors
  - `:invalid_amount` - Payment amount out of bounds
  - `:invalid_structure` - Webhook payload structure invalid
  - `:missing_fields` - Required fields missing
  - `:value_too_long` - String value exceeds max length

  ### State Errors
  - `:subscription_already_exists` - User already has active subscription
  - `:already_in_state` - Resource already in target state
  - `:rate_limited` - Too many requests

  ### System Errors
  - `:subscriptions_not_supported` - Subscription manager not configured
  - `:subscription_manager_unavailable` - Manager not loaded
  - `:transaction_not_found` - Transaction does not exist
  - `:transaction_creation_failed` - Failed to create transaction
  - `:transaction_update_failed` - Failed to update transaction

  ### Stripe Errors
  - `:payment_failed` - Payment processing failed
  - `:subscription_failed` - Subscription processing failed
  - `:retry_later` - Transient error, should retry

  ## Webhook Error Handling

  Webhook handlers use a special three-tuple pattern to indicate retry behavior:

      {:error, :retry_later, "Detailed message"}

  This tells the webhook processor to retry the webhook delivery.

  For permanent failures (should not retry):

      {:error, :payment_failed, "Detailed message"}

  ## Logging Best Practices

  When returning errors:

  1. **Always log errors** - Use appropriate log level
  2. **Include context** - User ID, transaction ID, etc.
  3. **Log before returning** - Don't rely on caller to log

  Example:

      Logger.error("Payment failed for user \#{user_id}",
        user_id: user_id,
        transaction_id: transaction.id,
        error: inspect(reason)
      )

      {:error, :payment_failed}

  ## Converting Between Error Patterns

  Use these helper functions to maintain consistency:

      # Convert changeset to simple atom
      case create_transaction(attrs) do
        {:ok, transaction} -> {:ok, transaction}
        {:error, %Ecto.Changeset{}} -> {:error, :validation_failed}
      end

      # Add context to simple atom
      case cancel_subscription(id, user_id) do
        {:ok, result} -> {:ok, result}
        {:error, :unauthorized} ->
          {:error, %{reason: :unauthorized, user_id: user_id, subscription_id: id}}
      end
  """

  @doc """
  Standard error atoms used across the payment system.
  """
  @spec error_atoms() :: [atom()]
  def error_atoms do
    [
      # Authentication & Authorization
      :unauthorized,
      :subscription_not_found,
      :user_not_found,

      # Validation Errors
      :invalid_amount,
      :invalid_structure,
      :missing_fields,
      :value_too_long,

      # State Errors
      :subscription_already_exists,
      :already_in_state,
      :rate_limited,

      # System Errors
      :subscriptions_not_supported,
      :subscription_manager_unavailable,
      :transaction_not_found,
      :transaction_creation_failed,
      :transaction_update_failed,

      # Payment/Stripe Errors
      :payment_failed,
      :subscription_failed,
      :retry_later
    ]
  end

  @doc """
  Checks if an error atom is a standard payment system error.
  """
  @spec standard_error?(atom()) :: boolean()
  def standard_error?(error_atom) when is_atom(error_atom) do
    error_atom in error_atoms()
  end

  def standard_error?(_error), do: false
end
