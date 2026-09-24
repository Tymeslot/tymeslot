defmodule Tymeslot.Auth.AccountDeletion do
  @moduledoc """
  Orchestrates account deletion.

  Runs the external-cleanup hook (e.g. SaaS subscription cancellation) before
  any DB change and, once that succeeds, runs the cross-domain
  anonymise-then-delete transaction spanning `Auth` and `MeetingPayments`,
  then removes the files the deleted rows pointed at.
  """

  require Logger

  alias Tymeslot.Auth.{Session, UserQueries, UserSchema, UserSessionQueries}
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.ThemeCustomizations

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

  Once the transaction commits, every live socket bound to one of the user's
  sessions is disconnected: the cascade removes the session rows, but a
  connected LiveView socket never re-reads them.

  Then the profile's uploaded avatars and theme
  backgrounds are removed from disk. The database cascade deletes only rows,
  and an avatar is usually a photo of the person, so leaving the files would
  keep personal data past an erasure request. Files go only after the commit:
  a rolled-back deletion must not leave live rows pointing at missing files.
  A file that cannot be removed is logged and does not fail the deletion,
  which has already happened.
  """
  @spec delete_account(UserSchema.t()) ::
          {:ok, UserSchema.t()} | {:error, Ecto.Changeset.t() | term()}
  def delete_account(%UserSchema{} = user) do
    with :ok <- run_account_deletion_hook(user.id) do
      # Resolved before the delete: the cascade removes the row that knows it.
      profile = Profiles.get_profile(user.id)

      user.id
      |> run_deletion_transaction(user)
      |> log_transaction_failure(user.id)
      |> disconnect_sessions()
      |> delete_uploaded_files(profile)
    end
  end

  # The session rows go with the user by FK cascade; their hashes are read
  # first, inside the same transaction, so the live sockets bound to them can
  # be told to disconnect once the deletion has committed.
  defp run_deletion_transaction(user_id, user) do
    Repo.transaction(fn ->
      session_hashes = UserSessionQueries.list_user_session_token_hashes(user_id)

      with :ok <- MeetingPayments.anonymise_host(user_id),
           {:ok, deleted} <- UserQueries.delete_user_row(user) do
        {deleted, session_hashes}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Only after the commit: a rolled-back deletion must leave its sessions
  # connected.
  defp disconnect_sessions({:ok, {deleted, session_hashes}}) do
    Enum.each(session_hashes, &Session.disconnect_session_hash/1)
    {:ok, deleted}
  end

  defp disconnect_sessions(error), do: error

  defp log_transaction_failure({:error, reason} = error, user_id) do
    Logger.error(
      "Account deletion DB transaction failed after the external deletion hook already ran " <>
        "(a subscription may have been cancelled) for user_id=#{user_id}: #{inspect(reason)}. " <>
        "Manual reconciliation required."
    )

    error
  end

  defp log_transaction_failure(result, _user_id), do: result

  defp delete_uploaded_files({:ok, deleted} = result, %{id: profile_id}) do
    for {kind, outcome} <- [
          avatars: Profiles.delete_avatar_files(profile_id),
          theme_backgrounds: ThemeCustomizations.delete_profile_files(profile_id)
        ],
        outcome != :ok do
      {:error, reason, path} = outcome

      Logger.error(
        "Account deleted but its uploaded files could not be removed; delete them by hand",
        user_id: deleted.id,
        profile_id: profile_id,
        files: kind,
        path: path,
        reason: inspect(reason)
      )
    end

    result
  end

  defp delete_uploaded_files(result, _profile), do: result

  defp run_account_deletion_hook(user_id) do
    case Application.get_env(:tymeslot, :account_deletion_hook) do
      nil -> :ok
      hook -> hook.on_account_deletion(user_id)
    end
  end
end
