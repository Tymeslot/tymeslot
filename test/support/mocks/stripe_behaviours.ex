defmodule Tymeslot.Mocks.StripeBehaviours do
  @moduledoc """
  Behaviours for the Stripe wrapper used by Mox-based payment tests.
  """

  defmodule StripeCustomerBehaviour do
    @moduledoc "Behaviour for Stripe Customer operations"
    @callback create(map(), list()) :: {:ok, map()} | {:error, any()}
  end

  defmodule StripeSessionBehaviour do
    @moduledoc "Behaviour for Stripe Session operations"
    @callback create(map(), list()) :: {:ok, map()} | {:error, any()}
    @callback retrieve(String.t(), map(), list()) :: {:ok, map()} | {:error, any()}
    @callback expire(String.t(), map(), list()) :: {:ok, map()} | {:error, any()}
  end

  defmodule StripeSubscriptionBehaviour do
    @moduledoc "Behaviour for Stripe Subscription operations"
    @callback create(map(), list()) :: {:ok, map()} | {:error, any()}
    @callback retrieve(String.t(), map(), list()) :: {:ok, map()} | {:error, any()}
    @callback update(String.t(), map(), list()) :: {:ok, map()} | {:error, any()}
    @callback cancel(String.t(), map(), list()) :: {:ok, map()} | {:error, any()}
  end

  defmodule StripeChargeBehaviour do
    @moduledoc "Behaviour for Stripe Charge operations"
    @callback retrieve(String.t(), map(), list()) :: {:ok, map()} | {:error, any()}
  end

  defmodule StripeWebhookBehaviour do
    @moduledoc "Behaviour for Stripe Webhook operations"
    @callback construct_event(binary(), String.t(), String.t()) :: {:ok, map()} | {:error, any()}
  end
end
