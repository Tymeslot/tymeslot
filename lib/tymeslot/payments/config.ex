defmodule Tymeslot.Payments.Config do
  @moduledoc """
  Centralized configuration access for payment system.
  Provides consistent interface for retrieving configured providers and repos.
  """

  @doc """
  Get subscription manager (if configured).

  Returns `nil` if no subscription manager is configured (Core standalone mode).
  In SaaS deployments, this should be configured via application environment.
  """
  @spec subscription_manager() :: module() | nil
  def subscription_manager do
    Application.get_env(:tymeslot, :subscription_manager)
  end
end
