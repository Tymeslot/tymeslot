defmodule Tymeslot.Auth.AccountDeletion do
  @moduledoc """
  Orchestrates account deletion.

  Runs the external-cleanup hook (e.g. SaaS subscription cancellation) before
  any DB change and, once that succeeds, runs the cross-domain
  anonymise-then-delete transaction spanning `Auth` and `MeetingPayments`.
  """

  require Logger

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Repo

  @doc """
  Deletes a user.

  Runs the configured `:account_deletion_hook` first; if it fails, the
  deletion is aborted and the user, along with all their data, is left
  intact. We never destroy a user while external state that keeps costing
  them money (an active subscription) could not be cancelled.

  On success, runs `Tymeslot.MeetingPayments.anonymise_host/1` before the
  delete so booking-payment and payment-transaction rows are scrubbed and
  marked retained. The ordering is what guarantees survival: anonymisation
  nils the host reference on each row (`booking_payments.host_user_id` is a
  bare integer with no FK; `payment_transactions.user_id` is set to nil)
  before the user row is deleted, so no retained row still points at the
  user when the delete runs — regardless of the FK's `on_delete`. Both must
  happen in the same transaction. Required for tax-record retention under EU
  and Swiss commercial law (GDPR Art. 17(3)(b) carve-out).
  """
  @spec delete_account(UserSchema.t()) ::
          {:ok, UserSchema.t()} | {:error, Ecto.Changeset.t() | term()}
  def delete_account(%UserSchema{} = user) do
    with :ok <- run_account_deletion_hook(user.id) do
      user.id
      |> run_deletion_transaction(user)
      |> log_transaction_failure(user.id)
    end
  end

  defp run_deletion_transaction(user_id, user) do
    Repo.transaction(fn ->
      with :ok <- MeetingPayments.anonymise_host(user_id),
           {:ok, deleted} <- UserQueries.delete_user_row(user) do
        deleted
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp log_transaction_failure({:error, reason} = error, user_id) do
    Logger.error(
      "Account deletion DB transaction failed after the external deletion hook already ran " <>
        "(a subscription may have been cancelled) for user_id=#{user_id}: #{inspect(reason)}. " <>
        "Manual reconciliation required."
    )

    error
  end

  defp log_transaction_failure(result, _user_id), do: result

  defp run_account_deletion_hook(user_id) do
    case Application.get_env(:tymeslot, :account_deletion_hook) do
      nil -> :ok
      hook -> hook.on_account_deletion(user_id)
    end
  end
end
