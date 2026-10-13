defmodule Tymeslot.Payments.Subscriptions do
  @moduledoc false

  require Logger

  alias Tymeslot.Payments.Config

  @spec cancel_subscription(String.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def cancel_subscription(subscription_id, user_id, opts \\ []) do
    manager = subscription_manager()

    if manager do
      manager.cancel_subscription(subscription_id, user_id, opts)
    else
      Logger.error("Subscription manager not configured")
      {:error, :subscriptions_not_supported}
    end
  end

  @spec update_subscription(String.t(), String.t(), pos_integer(), map()) ::
          {:ok, map()} | {:error, term()}
  def update_subscription(
        subscription_id,
        new_stripe_price_id,
        user_id,
        metadata \\ %{}
      ) do
    manager = subscription_manager()

    if manager do
      manager.update_subscription(
        subscription_id,
        new_stripe_price_id,
        user_id,
        metadata
      )
    else
      Logger.error("Subscription manager not configured")
      {:error, :subscriptions_not_supported}
    end
  end

  @spec downgrade_subscription(String.t(), String.t(), pos_integer(), map()) ::
          {:ok, map()} | {:error, term()}
  def downgrade_subscription(
        subscription_id,
        new_stripe_price_id,
        user_id,
        metadata \\ %{}
      ) do
    manager = subscription_manager()

    if manager && function_exported?(manager, :downgrade_subscription, 4) do
      manager.downgrade_subscription(
        subscription_id,
        new_stripe_price_id,
        user_id,
        metadata
      )
    else
      Logger.error("Subscription manager not configured or doesn't support downgrades")
      {:error, :downgrades_not_supported}
    end
  end

  @doc """
  Whether `user_id`'s outgoing material carries the free-tier "Tymeslot"
  branding. Off unless the instance enables `:show_branding` and a
  subscription manager is configured to answer for the user; an unknown user
  never gets it, so a paying customer cannot be branded by a missing id.
  """
  @spec show_branding?(pos_integer() | nil) :: boolean()
  def show_branding?(user_id) when is_integer(user_id) do
    manager = subscription_manager()

    Application.get_env(:tymeslot, :show_branding, false) == true and
      not is_nil(manager) and manager.should_show_branding?(user_id) == true
  end

  def show_branding?(_user_id), do: false

  defp subscription_manager do
    Config.subscription_manager()
  end
end
