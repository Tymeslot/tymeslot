defmodule Tymeslot.Auth.AccountDeletion do
  @moduledoc """
  Orchestrates account deletion.

  Runs the external-cleanup hook (e.g. SaaS subscription cancellation) before
  any DB change, then Core's own external cleanup, and only once both succeed
  runs the cross-domain anonymise-then-delete transaction spanning `Auth` and
  `MeetingPayments`.

  ## Why mirror teardown is not a hook

  `:account_deletion_hook` holds a *single* module and is reserved for an
  external layer — the SaaS billing overlay — to tear down state that keeps
  costing the user money. Claiming it from Core would mean whichever
  configuration loaded last silently won, and one of the two cleanups would
  simply never run.

  Withdrawing calendar mirror placeholders is Core's own pre-delete work, so it
  sits beside `MeetingPayments.anonymise_host/1` in the flow rather than in the
  hook slot. It runs *before* the transaction opens because it makes provider
  calls, and a database transaction held open across a round trip to Google
  puts connection-pool starvation and a slow calendar server on one fuse.
  """

  require Logger

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Integrations.Calendar.SyncLink.Teardown
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

  Between the hook and the transaction, every calendar mirror placeholder the
  user's sync links wrote is withdrawn from its provider. This is the last
  moment at which that is possible: the mapping rows naming those placeholders
  are destroyed with the user, and a busy block left on a calendar afterwards
  is indistinguishable from one the organiser created themselves. A teardown
  that cannot finish therefore aborts the deletion, on the same principle as a
  failing hook — never destroy a user while external state they can no longer
  reach was left behind.
  """
  @spec delete_account(UserSchema.t()) ::
          {:ok, UserSchema.t()} | {:error, Ecto.Changeset.t() | term()}
  def delete_account(%UserSchema{} = user) do
    with :ok <- run_account_deletion_hook(user.id),
         :ok <- tear_down_calendar_mirrors(user.id) do
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

  defp tear_down_calendar_mirrors(user_id) do
    case Teardown.tear_down_for_user(user_id) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.error(
          "Aborting account deletion: calendar mirror placeholders could not be withdrawn " <>
            "for user_id=#{user_id}: #{inspect(reason)}. Deleting the account now would strand " <>
            "busy blocks on the user's calendars with nothing able to identify them."
        )

        error
    end
  end

  defp run_account_deletion_hook(user_id) do
    case Application.get_env(:tymeslot, :account_deletion_hook) do
      nil -> :ok
      hook -> hook.on_account_deletion(user_id)
    end
  end
end
