defmodule Tymeslot.Payments.Config do
  @moduledoc """
  Centralized configuration access for payment system.
  Provides consistent interface for retrieving configured providers and repos.
  """

  @doc """
  Get configured Stripe provider module.

  Defaults to `Tymeslot.Payments.Stripe` if not configured.
  Can be overridden in tests via application config.
  """
  @spec stripe_provider() :: module()
  def stripe_provider do
    Application.get_env(:tymeslot, :stripe_provider, Tymeslot.Payments.Stripe)
  end

  @doc """
  Get Core repository.

  Defaults to `Tymeslot.Repo` if not configured.
  """
  @spec repo() :: module()
  def repo do
    Application.get_env(:tymeslot, :repo, Tymeslot.Repo)
  end

  @doc """
  Get subscription manager (if configured).

  Returns `nil` if no subscription manager is configured (Core standalone mode).
  In SaaS deployments, this should be configured via application environment.
  """
  @spec subscription_manager() :: module() | nil
  def subscription_manager do
    Application.get_env(:tymeslot, :subscription_manager)
  end

  @doc """
  Get subscription schema (if configured).

  Returns `nil` if no subscription schema is configured (Core standalone mode).
  """
  @spec subscription_schema() :: module() | nil
  def subscription_schema do
    Application.get_env(:tymeslot, :subscription_schema)
  end
end
