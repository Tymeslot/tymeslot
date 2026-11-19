defmodule Tymeslot.Features.CheckerBehaviour do
  @moduledoc """
  Behaviour contract for feature access checker implementations.

  Core provides `Tymeslot.Features.DefaultAccessChecker`, which returns
  `:ok` for almost every feature and gates a few on a runtime config flag.
  SaaS overrides the configured checker to gate features
  behind subscription tiers.
  """

  @callback check_access(user_id :: integer(), feature :: atom()) ::
              :ok
              | {:error,
                 :insufficient_plan | :feature_disabled | :pro_required | :stripe_required}
end
