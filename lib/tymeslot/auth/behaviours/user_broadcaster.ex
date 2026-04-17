defmodule Tymeslot.Auth.Behaviours.UserBroadcaster do
  @moduledoc """
  Behaviour for broadcasting auth user events.

  This allows the broadcaster to be swapped in tests without patching
  the global BEAM state.
  """

  @callback broadcast_user_registered(user :: map()) :: :ok | {:error, term()}
end
