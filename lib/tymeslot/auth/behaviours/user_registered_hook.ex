defmodule Tymeslot.Auth.Behaviours.UserRegisteredHook do
  @moduledoc """
  Optional hook run for every account that completes registration, letting
  an external layer record what it needs from the sign-up (for example, the
  terms acceptance and the request it came from).

  Configured via `config :tymeslot, :user_registered_hook, MyHook`. Core keeps
  a `nil` default and behaves identically whether or not a hook is set.

  The hook runs from an Oban job enqueued when the account is created, so it
  survives a restart and **`{:error, reason}` is retried** with the job's
  backoff. It must be safe to run more than once for the same user.

  `metadata` arrives JSON-decoded: string keys, string or boolean values.
  """

  @callback on_user_registered(user_id :: pos_integer(), metadata :: map()) ::
              :ok | {:error, term()}
end
