defmodule Tymeslot.Auth.Behaviours.AccountDeletionHook do
  @moduledoc """
  Hook into the account deletion lifecycle, letting an external layer (a
  billing overlay, say) manage state that lives outside Core's database.

  Configured via `config :tymeslot, :account_deletion_hook, MyHook`. Core keeps
  a safe `nil` default and behaves identically whether or not a hook is set.

    * `on_deletion_requested/2` runs once a deletion has been scheduled, with
      the user's optional exit feedback. Best-effort: an error is logged and
      the request stands.
    * `on_deletion_restored/1` runs once a pending deletion has been
      cancelled. Best-effort in the same way.
    * `on_account_deletion/1` runs right before the account is deleted.
      **Returning `{:error, reason}` aborts the deletion** and leaves the user
      and all their data intact; the deletion job retries later. We never
      destroy a user while external state that keeps costing them money could
      not be cancelled.

  Every callback may run more than once for the same user (jobs retry), so
  each must be idempotent and must return `:ok` for a user with nothing to do.
  """

  @typedoc "Exit feedback from the deletion dialog, or `nil` when none was given."
  @type feedback :: %{reason: String.t(), comment: String.t() | nil} | nil

  @callback on_deletion_requested(user_id :: pos_integer(), feedback()) :: :ok | {:error, term()}
  @callback on_deletion_restored(user_id :: pos_integer()) :: :ok | {:error, term()}
  @callback on_account_deletion(user_id :: integer()) :: :ok | {:error, term()}
end
