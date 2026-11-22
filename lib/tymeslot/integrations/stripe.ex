defmodule Tymeslot.Integrations.Stripe do
  @moduledoc """
  Tymeslot's Stripe API integration, built on Req.

  Features in Core and in the managed overlay call the resource modules under
  this namespace directly (`Stripe.Refunds.create/2`, `Stripe.Charges.retrieve/2`
  and so on). Each returns `{:ok, map}` with Stripe's object string-keyed, or
  `{:error, %Tymeslot.Integrations.Stripe.Error{}}`, or `{:error, :missing_api_key}`
  when no secret key is configured.

  `Client`, `Request`, `FormEncoder` and `RetryPolicy` are internal: they build,
  encode, send and retry one call, and nothing outside this namespace uses them.

  This module answers questions about the configuration itself: whether a key is
  set, whether it is a live one, and which API version requests pin. Settings
  live under `config :tymeslot, Tymeslot.Integrations.Stripe` and are read at
  runtime, so test and deployment config can override them.
  """

  @doc """
  The platform's secret key, or `nil` when none is set. A blank value counts as
  unset.
  """
  @spec secret_key() :: String.t() | nil
  def secret_key do
    Enum.find_value(
      [
        Application.get_env(:tymeslot, :stripe_secret_key),
        # Temporary: `STRIPE_SECRET_KEY` is still read into the stripity_stripe
        # app env at runtime, until the runtime config moves to the key above.
        Application.get_env(:stripity_stripe, :api_key)
      ],
      fn
        key when is_binary(key) and key != "" -> key
        _unset -> nil
      end
    )
  end

  @doc "Whether a secret key is configured."
  @spec configured?() :: boolean()
  def configured?, do: is_binary(secret_key())

  @doc "Whether the configured key is a live-mode key. False when none is set."
  @spec live_mode?() :: boolean()
  def live_mode? do
    case secret_key() do
      nil -> false
      key -> String.contains?(key, "_live_")
    end
  end

  @doc "The Stripe API version every request pins."
  @spec api_version() :: String.t()
  def api_version, do: Keyword.fetch!(settings(), :api_version)

  @doc false
  @spec settings() :: keyword()
  def settings, do: Application.get_env(:tymeslot, __MODULE__, [])
end
