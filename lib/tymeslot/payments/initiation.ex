defmodule Tymeslot.Payments.Initiation do
  @moduledoc false

  require Logger

  alias Tymeslot.Payments.{
    ChangesetHelpers,
    Config,
    DatabaseOperations,
    PendingTransactions,
    Preflight
  }

  @spec initiate_payment(
          pos_integer(),
          String.t(),
          pos_integer(),
          String.t(),
          String.t(),
          String.t(),
          map()
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
    system_metadata = %{
      user_id: user_id,
      product_identifier: product_identifier
    }

    with {:ok, sanitized_metadata} <-
           Preflight.sanitize_initiation(amount, user_id, metadata, system_metadata) do
      case PendingTransactions.get_pending_transaction_for_user(user_id) do
        {:ok, nil} ->
          create_new_payment_transaction(
            amount,
            product_identifier,
            user_id,
            email,
            success_url,
            cancel_url,
            sanitized_metadata
          )

        {:ok, existing_transaction} ->
          Logger.info("Superseding existing pending transaction",
            transaction_id: existing_transaction.id,
            user_id: user_id
          )

          with :ok <- PendingTransactions.supersede_pending_transaction(existing_transaction) do
            create_new_payment_transaction(
              amount,
              product_identifier,
              user_id,
              email,
              success_url,
              cancel_url,
              sanitized_metadata
            )
          end

        {:error, :transaction_lookup_failed} ->
          {:error, :retry_later}
      end
    end
  end

  defp create_new_payment_transaction(
         amount,
         product_identifier,
         user_id,
         email,
         success_url,
         cancel_url,
         metadata
       ) do
    attrs = %{
      user_id: user_id,
      amount: amount,
      product_identifier: product_identifier,
      status: "pending",
      metadata: metadata
    }

    with {:ok, transaction} <- DatabaseOperations.create_payment_transaction(attrs),
         {:ok, customer} <- stripe_provider().create_customer(email),
         {:ok, session} <-
           stripe_provider().create_session(
             customer,
             amount,
             transaction,
             success_url,
             cancel_url
           ),
         {:ok, _updated} <- DatabaseOperations.update_transaction_session(transaction, session) do
      Logger.info("Payment initiated", user_id: user_id)
      {:ok, session.url}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        if ChangesetHelpers.unique_pending_transaction_error?(changeset) do
          Logger.info("Race condition detected, retrying payment transaction creation",
            user_id: user_id
          )

          initiate_payment(
            amount,
            product_identifier,
            user_id,
            email,
            success_url,
            cancel_url,
            metadata
          )
        else
          Logger.error("Failed to create transaction", errors: inspect(changeset.errors))
          {:error, :transaction_creation_failed}
        end

      {:error, error} ->
        Logger.error("Payment initiation failed", error: inspect(error))
        {:error, error}
    end
  end

  defp stripe_provider do
    Config.stripe_provider()
  end
end
