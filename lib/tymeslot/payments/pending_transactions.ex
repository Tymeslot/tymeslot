defmodule Tymeslot.Payments.PendingTransactions do
  @moduledoc false

  require Logger

  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Stripe.CheckoutSessions
  alias Tymeslot.Payments.PaymentQueries
  alias Tymeslot.Payments.PaymentTransactionSchema, as: PaymentTransaction

  @type transaction :: PaymentTransaction.t()

  # Longer than every Stripe call a subscription checkout makes before its
  # session is recorded (a customer lookup, up to two creates and the
  # session, each with a 10-second deadline), with room to spare.
  @preparing_seconds 120

  @spec get_pending_transactions_for_user(pos_integer()) ::
          {:ok, [transaction()]} | {:error, :transaction_lookup_failed}
  def get_pending_transactions_for_user(user_id) do
    case PaymentQueries.get_transactions_by_status(:pending, user_id) do
      {:ok, transactions} ->
        {:ok, transactions}

      {:error, reason} ->
        ErrorTracking.report_error(reason, nil, %{user_id: user_id})
        {:error, :transaction_lookup_failed}
    end
  end

  @doc """
  Marks a pending transaction failed and expires its Checkout session, if it
  has one. The session is the one on the row when it was locked, so a session
  recorded by a request still finishing is expired too. A row no longer
  pending is left alone.
  """
  @spec supersede_pending_transaction(transaction()) :: :ok | {:error, term()}
  def supersede_pending_transaction(transaction) do
    metadata = %{
      "superseded" => true,
      "superseded_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    case PaymentQueries.fail_pending_transaction(transaction, metadata) do
      {:ok, superseded} ->
        expire_checkout_session_if_present(superseded)

      {:error, :not_pending} ->
        :ok

      {:error, error} ->
        Logger.error("Failed to supersede pending transaction", error: LogFormat.reason(error))
        {:error, :transaction_update_failed}
    end
  end

  defp expire_checkout_session_if_present(%{stripe_id: "cs_" <> _rest = session_id}),
    do: expire_checkout_session(session_id)

  defp expire_checkout_session_if_present(_transaction), do: :ok

  @doc """
  Expires a Checkout session at Stripe so it can no longer be paid, as a best
  effort: a failure is logged and the caller carries on.
  """
  @spec expire_checkout_session(String.t()) :: :ok
  def expire_checkout_session(session_id) when is_binary(session_id) do
    case CheckoutSessions.expire(session_id, []) do
      {:ok, _session} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to expire checkout session",
          session_id: session_id,
          reason: LogFormat.reason(reason)
        )
    end
  end

  @doc """
  Supersedes the user's pending transactions before a new checkout starts.

  One with no session yet, inserted under `#{@preparing_seconds}` seconds ago,
  belongs to a checkout whose Stripe calls are still running, and is left
  alone: the new checkout's insert then meets the one-pending-per-user index
  and waits for that checkout's URL instead of starting a second one. Its
  session would be recorded after any supersede, too late to be expired, and
  both would stay payable. Past the cutoff the request that inserted it has
  died or is about to find its row superseded, so it no longer blocks.
  """
  @spec supersede_pending_transaction_if_needed(pos_integer()) :: :ok | {:error, term()}
  def supersede_pending_transaction_if_needed(user_id) do
    case PaymentQueries.list_supersedable_pending_transactions(user_id, @preparing_seconds) do
      [] ->
        :ok

      pending_transactions ->
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
    end
  end
end
