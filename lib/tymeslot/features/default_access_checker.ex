defmodule Tymeslot.Features.DefaultAccessChecker do
  @moduledoc """
  Default implementation of feature access checking for Core.
  Always allows access to all features.
  """

  @behaviour Tymeslot.Features.CheckerBehaviour

  @impl Tymeslot.Features.CheckerBehaviour
  @spec check_access(integer(), atom()) :: :ok
  def check_access(_user_id, _feature), do: :ok
end
