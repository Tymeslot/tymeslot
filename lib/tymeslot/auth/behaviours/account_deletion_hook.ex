defmodule Tymeslot.Auth.Behaviours.AccountDeletionHook do
  @moduledoc """
  Optional hook invoked before a user account is deleted, letting an external
  layer (e.g. the SaaS billing overlay) tear down state that lives outside
  Core's database — most importantly a live Stripe subscription.

  Configured via `config :tymeslot, :account_deletion_hook, MyHook`. Core keeps
  a safe `nil` default and behaves identically whether or not a hook is set.

  **Returning `{:error, reason}` aborts the deletion.** `delete_user/1` returns
  the error and the user, along with all their data, is left intact. This is
  deliberate: we never destroy a user while external state that keeps costing
  them money (an active subscription) could not be cancelled. The hook must be
  safe to run for a user who has nothing to clean up (return `:ok`).
  """

  @callback on_account_deletion(user_id :: integer()) :: :ok | {:error, term()}
end
