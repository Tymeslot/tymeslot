defmodule Tymeslot.Auth.AccountDeletion do
  @moduledoc """
  Orchestrates account deletion.

  Runs the external-cleanup hook (e.g. SaaS subscription cancellation) before
  any DB change and, once that succeeds, runs the cross-domain
  anonymise-then-delete transaction spanning `Auth` and the payment records,
  then removes the files the deleted rows pointed at.
  """

  require Logger

  alias Tymeslot.Auth.AccountDeletion.{ExternalCleanup, Hook}
  alias Tymeslot.Auth.{Session, UserQueries, UserSchema}
  alias Tymeslot.FinancialRetention
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Jobs
  alias Tymeslot.Meetings
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.Workers.AccountFilesPurgeWorker

  @doc """
  Deletes a user.

  Runs the configured `:account_deletion_hook` first; if it fails, the
  deletion is aborted and the user, along with all their data, is left
  intact. We never destroy a user while external state that keeps costing
  them money (an active subscription) could not be cancelled.

  On success, runs `Tymeslot.FinancialRetention.anonymise_host/1` before the
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
  A file that cannot be removed does not fail the deletion, which has
  already happened: the removal is retried in the background
  (`Tymeslot.Workers.AccountFilesPurgeWorker`), and the operator is alerted
  if it never succeeds.

  Options:

    * `only_if_pending: true`: the row is deleted only if, under a row lock,
      it is pending and due (`deletion_scheduled_at` set and not in the
      future); otherwise `{:error, :not_pending}`. The grace period ends at
      `deletion_scheduled_at`, so a due account is past restoring.
    * `only_if_purgeable: cutoff`: the purge of abandoned sign-ups. The
      account must still be one `UserQueries.stale_unverified_user?/2`
      accepts for `cutoff` (unverified, not an admin, no meeting still to
      come); otherwise `{:error, :not_purgeable}`. Checked before the hook
      runs, so an account already ineligible keeps its subscription, and
      again under the row lock, so one verified, promoted or booked in the
      meantime is not deleted.
    * `meeting_ids: ids`: inside the same transaction, every job still
      waiting that names the user or one of these meetings is deleted, so a
      committed deletion never leaves such a job behind (and a rolled-back one
      never loses them).

  A user already gone yields `{:error, :not_found}` under `only_if_pending: true`
  or `only_if_purgeable:`.
  """
  @spec delete_account(UserSchema.t(), keyword()) ::
          {:ok, UserSchema.t()}
          | {:error, :not_pending | :not_purgeable | :not_found | Ecto.Changeset.t() | term()}
  def delete_account(%UserSchema{} = user, opts \\ []) do
    with :ok <- confirm_purgeable(user.id, Keyword.get(opts, :only_if_purgeable)),
         :ok <- Hook.deleted(user.id) do
      # Resolved before the delete: the cascade removes the row that knows it.
      profile = Profiles.get_profile(user.id)

      user
      |> run_deletion_transaction(opts)
      |> log_transaction_failure(user.id)
      |> disconnect_sessions()
      |> delete_uploaded_files(profile)
    end
  end

  # The session rows are deleted first, inside the same transaction, and their
  # hashes kept, so the live sockets bound to them can be told to disconnect
  # once the deletion has committed.
  defp run_deletion_transaction(user, opts) do
    Repo.transaction(fn ->
      # Before the user row: the cascade reaches every cached calendar event,
      # which a sync may be writing under its integration cache lock.
      Calendar.lock_calendar_caches(user.id)

      with :ok <- confirm_due_for_deletion(user.id, Keyword.get(opts, :only_if_pending, false)),
           :ok <- confirm_still_purgeable(user.id, Keyword.get(opts, :only_if_purgeable)),
           session_hashes = Session.delete_session_rows(user.id),
           :ok <- FinancialRetention.anonymise_host(user.id),
           {:ok, deleted} <- UserQueries.delete_user_row(user) do
        clear_pending_jobs(user.id, Keyword.get(opts, :meeting_ids))
        {deleted, session_hashes}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp clear_pending_jobs(_user_id, nil), do: :ok

  defp clear_pending_jobs(user_id, meeting_ids) do
    Jobs.delete_pending_account_jobs(user_id, meeting_ids)
    :ok
  end

  # A restore locks the same row, so it either commits before this check (and
  # the deletion stops) or waits until the row is gone. The date is checked as
  # well as its presence: a restore followed by a fresh request leaves the
  # account pending but with a new, later date, and its grace period is not
  # over.
  defp confirm_due_for_deletion(_user_id, false), do: :ok

  defp confirm_due_for_deletion(user_id, true) do
    case UserQueries.get_user_for_update(user_id) do
      {:ok, %UserSchema{deletion_scheduled_at: %DateTime{} = at}} ->
        if DateTime.compare(at, DateTime.utc_now()) == :gt,
          do: {:error, :not_pending},
          else: :ok

      {:ok, _restored} ->
        {:error, :not_pending}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # Unlocked: run before anything leaves the database (grants revoked, the
  # hook cancelling a subscription), so an account the purge no longer
  # applies to loses nothing. The locked check below closes the window
  # between this read and the delete.
  defp confirm_purgeable(_user_id, nil), do: :ok

  defp confirm_purgeable(user_id, %DateTime{} = cutoff) do
    if UserQueries.stale_unverified_user?(user_id, cutoff),
      do: :ok,
      else: {:error, :not_purgeable}
  end

  # Verifying an account updates this row, so it either commits before the
  # lock (and the check below sees it) or waits until the row is gone.
  defp confirm_still_purgeable(_user_id, nil), do: :ok

  defp confirm_still_purgeable(user_id, cutoff) do
    with {:ok, _user} <- UserQueries.get_user_for_update(user_id) do
      confirm_purgeable(user_id, cutoff)
    end
  end

  # Only after the commit: a rolled-back deletion must leave its sessions
  # connected.
  defp disconnect_sessions({:ok, {deleted, session_hashes}}) do
    :ok = Session.disconnect_sessions(session_hashes)
    {:ok, deleted}
  end

  defp disconnect_sessions(error), do: error

  defp log_transaction_failure({:error, :not_pending} = error, user_id) do
    Logger.warning(
      "Account restored or rescheduled while its deletion was running; " <>
        "the deletion hook had already run",
      user_id: user_id
    )

    error
  end

  defp log_transaction_failure({:error, :not_purgeable} = error, user_id) do
    Logger.warning(
      "Unverified account stopped being purgeable while its purge was running; " <>
        "the deletion hook had already run",
      user_id: user_id
    )

    error
  end

  # Deleted by someone else between the read and the lock: nothing failed.
  defp log_transaction_failure({:error, :not_found} = error, user_id) do
    Logger.info("Account already deleted when its deletion transaction ran", user_id: user_id)
    error
  end

  defp log_transaction_failure({:error, reason} = error, user_id) do
    Logger.error(
      "Account deletion DB transaction failed after the external deletion hook already ran " <>
        "(a subscription may have been cancelled). Manual reconciliation required.",
      user_id: user_id,
      reason: LogFormat.reason(reason)
    )

    error
  end

  defp log_transaction_failure(result, _user_id), do: result

  # A file that cannot be removed now is retried in the background, and the
  # operator is told if it never goes; the deletion itself has already
  # happened and is not undone.
  defp delete_uploaded_files({:ok, deleted} = result, %{id: profile_id}) do
    with {:error, failures} <- AccountFilesPurgeWorker.purge(profile_id) do
      Logger.warning("Account deleted but its uploaded files could not be removed yet; retrying",
        user_id: deleted.id,
        profile_id: profile_id,
        files: Enum.map(failures, & &1.files),
        reason: LogFormat.reason(hd(failures).reason)
      )

      retry_file_purge(profile_id, failures)
    end

    result
  end

  defp delete_uploaded_files(result, _profile), do: result

  defp retry_file_purge(profile_id, failures) do
    case AccountFilesPurgeWorker.enqueue(profile_id) do
      {:ok, _job} -> :ok
      {:error, _reason} -> AccountFilesPurgeWorker.report(profile_id, failures)
    end
  end

  @doc """
  Erases a user for good: cleans up what the account left with third parties
  (`ExternalCleanup`), reads the ids of the meetings it organised before the
  cascade removes them, then runs `delete_account/2` with `opts` plus those ids
  as `:meeting_ids`, so no pending job naming the user or one of their
  meetings outlives the account.

  Both routes that delete an account without its owner present go through
  here: the deletion job once the grace period ends, and the purge of
  abandoned sign-ups. Under `only_if_purgeable:` the account is checked
  before the cleanup, so one that is no longer purgeable keeps its grants;
  the deletion job checks the account is due before it calls this.
  """
  @spec erase_account(UserSchema.t(), keyword()) ::
          {:ok, UserSchema.t()}
          | {:error, :not_pending | :not_purgeable | :not_found | Ecto.Changeset.t() | term()}
  def erase_account(%UserSchema{} = user, opts \\ []) do
    with :ok <- confirm_purgeable(user.id, Keyword.get(opts, :only_if_purgeable)) do
      ExternalCleanup.run(user)
      meeting_ids = Meetings.list_meeting_ids_for_organizer(user.id)

      delete_account(user, Keyword.put(opts, :meeting_ids, meeting_ids))
    end
  end

  # A daily run deletes at most this many, so a sign-up flood cannot turn one
  # run into an unbounded loop of deletions; the rest go on the following days.
  @purge_batch_size 500

  @doc """
  Deletes accounts still unverified `days` after sign-up, through
  `erase_account/2`, so each goes exactly as an erasure request would.

  An unverified account cannot sign in, so after a month it is an abandoned
  sign-up, or one made with somebody else's address, holding an email
  address and the IP it was registered from. Admins are spared, and so is an
  account sent a fresh verification link within the window: see
  `Tymeslot.Auth.UserQueries.list_stale_unverified_users/3`. So is every
  account the deployment's deletion hook protects
  (`c:Tymeslot.Auth.Behaviours.AccountDeletionHook.purge_protected_user_ids/0`,
  a paying subscriber, say); if the hook cannot say which
  those are, nothing is deleted. Each account is re-checked before anything
  of it is touched and again under its row lock (`only_if_purgeable:`). At
  most #{@purge_batch_size} are deleted per call, and none for a `days`
  below one.

  Returns `{deleted_count, nil}`, the shape `Tymeslot.Workers.DataRetentionWorker`
  expects of a prune function.
  """
  @spec purge_unverified_accounts(integer()) :: {non_neg_integer(), nil}
  def purge_unverified_accounts(days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    case Hook.purge_protected_user_ids() do
      {:ok, protected_ids} ->
        deleted =
          cutoff
          |> UserQueries.list_stale_unverified_users(@purge_batch_size, protected_ids)
          |> Enum.count(&purged?(&1, cutoff))

        {deleted, nil}

      {:error, reason} ->
        Logger.error(
          "Skipped the purge of unverified accounts: the deletion hook could not name " <>
            "the accounts it protects",
          reason: LogFormat.reason(reason)
        )

        {0, nil}
    end
  end

  # A zero or negative window would select every unverified account, however
  # new: the retention worker passes such values through from job args, and
  # they must delete nothing.
  def purge_unverified_accounts(_days), do: {0, nil}

  defp purged?(user, cutoff) do
    case erase_account(user, only_if_purgeable: cutoff) do
      {:ok, _deleted} ->
        Logger.info("Purged an unverified account", user_id: user.id)
        true

      {:error, reason} when reason in [:not_purgeable, :not_found] ->
        Logger.info("Unverified account not purged: no longer eligible, or already deleted",
          user_id: user.id,
          reason: reason
        )

        false

      {:error, reason} ->
        Logger.error("Could not purge an unverified account",
          user_id: user.id,
          reason: LogFormat.reason(reason)
        )

        false
    end
  end
end
