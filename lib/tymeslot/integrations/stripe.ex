defmodule Tymeslot.Integrations.Stripe do
  @moduledoc """
  Tymeslot's Stripe API integration, built on Req.

  Features in Core and in the managed overlay call the resource modules under
  this namespace directly (`Stripe.Refunds.create/2`, `Stripe.Charges.retrieve/2`
  and so on). Each returns `{:ok, map}` with Stripe's object string-keyed, or
  `{:error, %Tymeslot.Integrations.Stripe.Error{}}`, or `{:error, :missing_api_key}`
  when no secret key is configured (`t:result/0`).

  Every resource function takes an optional trailing `opts` keyword list:
  `:api_key` (otherwise the configured key), `:connect_account` (sent as the
  `Stripe-Account` header), `:idempotency_key` (POSTs get a random one when
  none is given; use `Stripe.IdempotencyKey.for_intent/3` for a stable one)
  and the timeouts `:deadline_ms`, `:receive_timeout` and `:connect_timeout`.
  An unknown option raises `ArgumentError`.

  `Client`, `Request`, `FormEncoder` and `RetryPolicy` are internal: they build,
  encode, send and retry one call, and nothing outside this namespace uses them.

  This module answers questions about the configuration itself: whether a key is
  set, whether it is a live one, and which API version requests pin. Settings
  live under `config :tymeslot, Tymeslot.Integrations.Stripe` and are read at
  runtime, so test and deployment config can override them.
  """

  alias Tymeslot.Integrations.Stripe.Error

  @typedoc "What every Stripe call returns: the string-keyed object, or why it failed."
  @type result :: {:ok, map()} | {:error, Error.t() | :missing_api_key}

  @doc """
  The platform's secret key, or `nil` when none is set. A blank value counts as
  unset.
  """
  @spec secret_key() :: String.t() | nil
  def secret_key do
    case Application.get_env(:tymeslot, :stripe_secret_key) do
      key when is_binary(key) and key != "" -> key
      _unset -> nil
    end
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
