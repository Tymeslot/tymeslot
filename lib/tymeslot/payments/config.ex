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
  The Stripe platform API key, or `nil` when none is configured.

  Read from `:tymeslot, :stripe_secret_key`, falling back to
  `:stripity_stripe, :api_key` (which `STRIPE_SECRET_KEY` sets at runtime).
  A blank value counts as unset. Every caller that needs the key resolves it
  here, so the order of the two settings cannot drift between them.
  """
  @spec stripe_api_key() :: String.t() | nil
  def stripe_api_key do
    Enum.find_value(
      [
        Application.get_env(:tymeslot, :stripe_secret_key),
        Application.get_env(:stripity_stripe, :api_key)
      ],
      fn
        key when is_binary(key) and key != "" -> key
        _unset -> nil
      end
    )
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
end
