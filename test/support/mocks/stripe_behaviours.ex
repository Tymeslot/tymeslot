defmodule Tymeslot.Mocks.StripeBehaviours do
  @moduledoc """
  Behaviours for the Stripe wrapper used by Mox-based payment tests.
  """

  defmodule StripeCustomerBehaviour do
    @moduledoc "Behaviour for Stripe Customer operations"
    @callback create(map(), list()) :: {:ok, map()} | {:error, any()}
    @callback delete(String.t(), list()) :: {:ok, map()} | {:error, any()}
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
    @callback list(map(), list()) :: {:ok, map()} | {:error, any()}
  end

  defmodule StripeInvoiceBehaviour do
    @moduledoc "Behaviour for Stripe Invoice operations"
    @callback retrieve(String.t(), map(), list()) :: {:ok, map()} | {:error, any()}
    @callback list(map(), list()) :: {:ok, map()} | {:error, any()}
  end

  defmodule StripeInvoicePaymentBehaviour do
    @moduledoc "Behaviour for Stripe InvoicePayment operations"
    @callback list(map(), list()) :: {:ok, map()} | {:error, any()}
  end
end
