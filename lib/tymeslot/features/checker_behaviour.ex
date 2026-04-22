defmodule Tymeslot.Features.CheckerBehaviour do
  @moduledoc """
  Behaviour contract for feature access checker implementations.

  Core provides `Tymeslot.Features.DefaultAccessChecker` which always
  returns `:ok`. SaaS overrides the configured checker to gate features
  behind subscription tiers.
  """

  @callback check_access(user_id :: integer(), feature :: atom()) ::
              :ok | {:error, :insufficient_plan}
end
