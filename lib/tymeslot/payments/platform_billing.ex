defmodule Tymeslot.Payments.PlatformBilling do
  @moduledoc """
  The platform account's subscription billing calls that carry decisions of
  their own beyond the Stripe request: the parameters a new customer gets, and
  the idempotency key each call is sent under.

  This is the API a subscription manager (`:subscription_manager`) calls for
  them, directly; every other Stripe call goes to the resource modules of
  `Tymeslot.Integrations.Stripe`.

  Results are Stripe's objects as Stripe sent them (string-keyed maps), or
  `{:error, %Tymeslot.Integrations.Stripe.Error{}}`, or
  `{:error, :missing_api_key}`.
  """

  require Logger

  alias Tymeslot.Integrations.Stripe.{
    CheckoutSessions,
    Client,
    Customers,
    Error,
    IdempotencyKey,
    Subscriptions
  }

  alias Tymeslot.Security.SecurityLogger

  @doc """
  Creates a Stripe customer for an email, or from a params map carrying
  `:email` and optionally `:metadata`, `:name`, `:phone` and `:address`.
  Without `:metadata` the customer is marked `is_business: pending`.

  `intent_id:` names what the customer is created for (a checkout request),
  so a repeat of that request replays Stripe's answer instead of creating a
  second customer; without it each call gets its own key.
  """
  @spec create_customer(String.t() | map(), keyword()) :: Client.result()
  def create_customer(email_or_params, opts \\ [])

  def create_customer(email, opts) when is_binary(email),
    do: create_customer(%{email: email}, opts)

  def create_customer(params, opts) when is_map(params) do
    opts = Keyword.validate!(opts, [:intent_id])
    email = params.email
    Logger.info("Creating Stripe customer", email_masked: SecurityLogger.mask_email(email))

    customer_params =
      Map.merge(
        %{
          email: email,
          metadata: Map.get(params, :metadata, %{"is_business" => "pending"})
        },
        Map.take(params, [:name, :phone, :address])
      )

    Customers.create(customer_params, key_opts(:customer, opts[:intent_id]))
  end

  @doc """
  Finds the customer already created for a user: the newest of those sharing
  `email` whose `"user_id"` metadata is `user_id`. `{:ok, nil}` when there is
  none, so a user who starts a second checkout does not get a second
  customer. Only customers created with a `"user_id"` metadata entry can
  match.
  """
  @spec find_customer(String.t(), integer() | String.t()) ::
          {:ok, map() | nil} | {:error, Error.t() | :missing_api_key}
  def find_customer(email, user_id) when is_binary(email) do
    user_id = to_string(user_id)

    with {:ok, %{"data" => customers}} <- Customers.list(%{email: email, limit: 10}) do
      {:ok,
       customers
       |> Enum.filter(&(get_in(&1, ["metadata", "user_id"]) == user_id))
       |> Enum.max_by(&Map.get(&1, "created", 0), fn -> nil end)}
    end
  end

  @doc """
  Creates a Checkout session in subscription mode, keyed on the
  `"checkout_request_id"` in its metadata, so a repeated request for the same
  checkout returns the same session. Without one, the call gets its own key.
  """
  @spec create_subscription_checkout(map()) :: Client.result()
  def create_subscription_checkout(params) when is_map(params) do
    Logger.info("Creating Stripe subscription checkout session")

    metadata = Map.get(params, :metadata, %{})

    request_id =
      Map.get(metadata, "checkout_request_id") || Map.get(metadata, :checkout_request_id)

    if is_nil(request_id) do
      Logger.debug("Subscription checkout has no checkout request id; sending a per-call key")
    end

    CheckoutSessions.create(params, key_opts(:subscription_checkout, request_id))
  end

  @doc """
  Cancels a subscription at the end of its period (the default) or, with
  `at_period_end: false`, at once.

  Neither call carries a chosen key: setting the flag reads the same to
  Stripe however often it is sent, and a second cancel now answers "already
  cancelled". Each call gets its own key, so a stored failure is never
  replayed to a retry. Passing `:idempotency_key` raises `ArgumentError`.
  """
  @spec cancel_subscription(String.t(), keyword()) :: Client.result()
  def cancel_subscription(subscription_id, opts) when is_binary(subscription_id) do
    opts = Keyword.validate!(opts, [:at_period_end])
    Logger.info("Canceling Stripe subscription", subscription_id: subscription_id)

    if Keyword.get(opts, :at_period_end, true) do
      Subscriptions.update(subscription_id, %{cancel_at_period_end: true}, [])
    else
      Subscriptions.cancel(subscription_id, %{}, [])
    end
  end

  defp key_opts(_kind, nil), do: []
  defp key_opts(kind, id), do: [idempotency_key: IdempotencyKey.for_intent(kind, id)]
end
