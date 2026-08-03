defmodule Tymeslot.Payments.PendingTransactions do
  @moduledoc false

  require Logger

  alias Tymeslot.Payments.Config
  alias Tymeslot.Payments.PaymentQueries
  alias Tymeslot.Payments.PaymentTransactionSchema, as: PaymentTransaction

  @type transaction :: PaymentTransaction.t()

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
    expire_checkout_session_if_present(transaction)

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
        Logger.error("Failed to supersede pending transaction", error: inspect(error))
        {:error, :transaction_update_failed}
    end
  end

  defp expire_checkout_session_if_present(%{stripe_id: "cs_" <> _rest = session_id}) do
    case Config.stripe_provider().expire_checkout_session(session_id) do
      {:ok, _session} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to expire superseded checkout session",
          session_id: session_id,
          reason: inspect(reason)
        )
    end
  end

  defp expire_checkout_session_if_present(_transaction), do: :ok

  @spec supersede_pending_transaction_if_needed(pos_integer()) ::
          :ok | {:error, :transaction_lookup_failed | term()}
  def supersede_pending_transaction_if_needed(user_id) do
    case get_pending_transactions_for_user(user_id) do
      {:ok, []} ->
        :ok

      {:ok, pending_transactions} ->
        Logger.info("Superseding pending transactions",
          user_id: user_id,
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
