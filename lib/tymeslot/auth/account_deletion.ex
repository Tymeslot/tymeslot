defmodule Tymeslot.Auth.AccountDeletion do
  @moduledoc """
  The public entry point for deleting accounts: the grace-period policy, a
  user's own request and its cancellation, an operator's immediate deletion,
  the scheduled run and the purge of accounts never verified.

  The work lives in the siblings this module delegates to: `Policy`,
  `Request`, `Restore`, `Operator`, `Runner` and `Purge`. Whether an account
  is pending deletion is a user-state question and stays on
  `Tymeslot.Auth.deletion_pending?/1`.
  """

  alias Tymeslot.Auth.AccountDeletion.{Operator, Policy, Purge, Request, Restore, Runner}
  alias Tymeslot.Auth.UserSchema

  @doc "Days between a deletion request and the deletion (0: straight away)."
  @spec account_deletion_grace_days() :: non_neg_integer()
  defdelegate account_deletion_grace_days(), to: Policy, as: :grace_days

  @doc "When an account asked to be deleted at `now` will be deleted."
  @spec account_deletion_due_at(DateTime.t()) :: DateTime.t()
  defdelegate account_deletion_due_at(now), to: Policy, as: :scheduled_at

  @doc "The date of `at` as the user's own calendar day (profile timezone, else UTC)."
  @spec deletion_local_date(DateTime.t(), UserSchema.t()) :: Date.t()
  def deletion_local_date(at, %UserSchema{id: user_id}), do: Policy.user_local_date(at, user_id)

  @doc "Whether the deletion dialog asks why the user is leaving."
  @spec collect_deletion_feedback?() :: boolean()
  defdelegate collect_deletion_feedback?(), to: Policy, as: :collect_feedback?

  @doc "The reasons the deletion dialog offers, as stored values."
  @spec deletion_feedback_reasons() :: [String.t()]
  defdelegate deletion_feedback_reasons(), to: Policy, as: :feedback_reasons

  @doc "Whether `user` confirms a deletion with its password or its email address."
  @spec deletion_confirmation_method(UserSchema.t()) :: :password | :email
  defdelegate deletion_confirmation_method(user), to: Policy, as: :confirmation_method

  @doc """
  Schedules the deletion of `user`'s own account. See
  `Tymeslot.Auth.AccountDeletion.Request`. `opts` must carry `:ip`; it may
  carry `:user_agent` and `:current_session_token`.
  """
  @spec request_account_deletion(UserSchema.t(), map(), keyword()) ::
          {:ok, UserSchema.t()} | Request.error()
  def request_account_deletion(user, params, opts),
    do: Request.request(user, params, request_opts!(opts))

  @doc "Whether `user`'s pending deletion can still be cancelled at `now`."
  @spec account_restorable?(UserSchema.t(), DateTime.t()) :: boolean()
  defdelegate account_restorable?(user, now), to: Restore, as: :restorable?

  @doc """
  Cancels the pending deletion of `user`'s account, while its grace period
  lasts; `{:error, :deletion_in_progress}` once the account is due.
  """
  @spec restore_account(UserSchema.t()) ::
          {:ok, UserSchema.t()} | {:error, :not_pending | :deletion_in_progress | term()}
  defdelegate restore_account(user), to: Restore, as: :restore

  @doc """
  Deletes another account now, bypassing the grace period, for the admin
  users tab or a release shell. See `Tymeslot.Auth.AccountDeletion.Operator`.
  """
  @spec delete_account_now(Operator.actor(), pos_integer(), keyword()) ::
          {:ok, UserSchema.t()} | {:error, Operator.error()}
  defdelegate delete_account_now(actor, user_id, opts \\ []), to: Operator, as: :delete_now

  @doc """
  Deletes a user account.

  Runs the configured account-deletion hook (e.g. SaaS subscription
  cancellation) before any database change; if it fails, the deletion is
  aborted and the user is left intact. On success, anonymises payment
  records and deletes the user row in a single transaction. See
  `Tymeslot.Auth.AccountDeletion.Purge.delete_account/2`.
  """
  @spec delete_account(UserSchema.t()) ::
          {:ok, UserSchema.t()} | {:error, Ecto.Changeset.t() | term()}
  def delete_account(user), do: Purge.delete_account(user)

  @doc """
  Deletes accounts still unverified `days` after sign-up. See
  `Tymeslot.Auth.AccountDeletion.Purge.purge_unverified_accounts/1`.
  """
  @spec purge_unverified_accounts(integer()) :: {non_neg_integer(), nil}
  defdelegate purge_unverified_accounts(days), to: Purge

  @doc """
  Deletes one account if it is pending and due. See
  `Tymeslot.Auth.AccountDeletion.Runner.run/2` for the outcomes.
  """
  @spec run_scheduled_deletion(integer(), keyword()) :: Runner.outcome()
  defdelegate run_scheduled_deletion(user_id, opts \\ []), to: Runner, as: :run

  @doc "Queues a deletion job for every overdue account; returns how many."
  @spec enqueue_overdue_account_deletions() :: non_neg_integer()
  defdelegate enqueue_overdue_account_deletions(), to: Runner, as: :enqueue_overdue

  # As in `Tymeslot.Auth`: a rate-limited entry point needs to know who is
  # asking, so a missing `:ip` is a caller bug rather than a shared bucket.
  defp request_opts!(opts) do
    _ip = Keyword.fetch!(opts, :ip)
    opts
  end
end
