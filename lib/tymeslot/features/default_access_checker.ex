defmodule Tymeslot.Features.DefaultAccessChecker do
  @moduledoc """
  Default implementation of feature access checking for Core.

  Most features open unconditionally so a self-hoster never hits a
  paywall. A small set of features (e.g. `:meeting_payments`) gate on a
  runtime config flag — the feature is a self-host opt-in even though
  there is no subscription plan to enforce.
  """

  @behaviour Tymeslot.Features.CheckerBehaviour

  @impl Tymeslot.Features.CheckerBehaviour
  @spec check_access(integer(), atom()) ::
          :ok | {:error, :feature_disabled}
  def check_access(_user_id, :meeting_payments) do
    if Application.get_env(:tymeslot, :meeting_payments_enabled, false),
      do: :ok,
      else: {:error, :feature_disabled}
  end

  def check_access(_user_id, _feature), do: :ok
end
