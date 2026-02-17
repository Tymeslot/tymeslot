defmodule Tymeslot.Payments.PendingTransactions do
  @moduledoc false

  require Logger

  alias Tymeslot.DatabaseQueries.PaymentQueries
  alias Tymeslot.DatabaseSchemas.PaymentTransactionSchema, as: PaymentTransaction

  @type transaction :: PaymentTransaction.t()

  @spec get_pending_transaction_for_user(pos_integer()) ::
          {:ok, transaction() | nil} | {:error, :transaction_lookup_failed}
  def get_pending_transaction_for_user(user_id) do
    case PaymentQueries.get_transactions_by_status("pending", user_id) do
      {:ok, [transaction | _rest]} ->
        {:ok, transaction}

      {:ok, []} ->
        {:ok, nil}

      {:error, reason} ->
        Logger.error("Failed to fetch pending transaction", error: inspect(reason))
        {:error, :transaction_lookup_failed}
    end
  end

  @spec get_pending_transactions_for_user(pos_integer()) ::
          {:ok, [transaction()]} | {:error, :transaction_lookup_failed}
  def get_pending_transactions_for_user(user_id) do
    case PaymentQueries.get_transactions_by_status("pending", user_id) do
      {:ok, transactions} ->
        {:ok, transactions}

      {:error, reason} ->
        Logger.error("Failed to fetch pending transactions", error: inspect(reason))
        {:error, :transaction_lookup_failed}
    end
  end

  @spec supersede_pending_transaction(transaction()) :: :ok | {:error, term()}
  def supersede_pending_transaction(transaction) do
    update_attrs = %{
      status: "failed",
      metadata:
        Map.merge(transaction.metadata, %{
          "superseded" => true,
          "superseded_at" => DateTime.to_iso8601(DateTime.utc_now())
        })
    }

    case PaymentQueries.update_transaction(transaction, update_attrs) do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        Logger.error("Failed to supersede pending transaction: #{inspect(error)}")
        {:error, :transaction_update_failed}
    end
  end

  @spec supersede_pending_transaction_if_needed(pos_integer()) ::
          :ok | {:error, :transaction_lookup_failed | term()}
  def supersede_pending_transaction_if_needed(user_id) do
    case get_pending_transactions_for_user(user_id) do
      {:ok, []} ->
        :ok

      {:ok, pending_transactions} ->
        Logger.info("Superseding pending transactions for user #{user_id}",
          count: length(pending_transactions)
        )

        Enum.reduce_while(pending_transactions, :ok, fn pending_transaction, _result ->
          case supersede_pending_transaction(pending_transaction) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
