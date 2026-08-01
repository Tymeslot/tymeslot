defmodule Tymeslot.MeetingPayments.StripeAdapter do
  @moduledoc """
  Single seam for every Stripe API call made by the meeting_payments
  context. The default implementation passes calls through to
  stripity_stripe; tests replace it with a Mox stub via the
  `:tymeslot, :stripe_adapter` config.

  Every call is wrapped in `Tymeslot.MeetingPayments.Telemetry.span_stripe/3`
  so dashboards can chart per-operation latency and error rate. Webhook
  signature construction is excluded — it never makes a network call.
  """

  alias Tymeslot.MeetingPayments.Telemetry

  @callback create_account(params :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback retrieve_account(account_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback create_account_link(params :: map()) ::
              {:ok, map()} | {:error, term()}
  @callback create_checkout_session(params :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback retrieve_checkout_session(session_id :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback retrieve_payment_intent(intent_id :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback retrieve_charge(charge_id :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback expire_checkout_session(session_id :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback create_refund(params :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback construct_webhook_event(
              payload :: binary(),
              signature :: String.t(),
              secret :: String.t()
            ) ::
              {:ok, map()} | {:error, term()}

  @spec create_account(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_account(params, opts \\ []) do
    Telemetry.span_stripe(:create_account, nil, fn -> impl().create_account(params, opts) end)
  end

  @spec retrieve_account(String.t()) :: {:ok, map()} | {:error, term()}
  def retrieve_account(id) do
    normalise_read(
      Telemetry.span_stripe(:retrieve_account, id, fn -> impl().retrieve_account(id) end)
    )
  end

  @spec create_account_link(map()) :: {:ok, map()} | {:error, term()}
  def create_account_link(params) do
    Telemetry.span_stripe(:create_account_link, params[:account], fn ->
      impl().create_account_link(params)
    end)
  end

  @spec create_checkout_session(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_checkout_session(params, opts \\ []) do
    Telemetry.span_stripe(:create_checkout_session, opts[:connect_account], fn ->
      impl().create_checkout_session(params, opts)
    end)
  end

  @spec retrieve_checkout_session(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def retrieve_checkout_session(id, opts \\ []) do
    normalise_read(
      Telemetry.span_stripe(:retrieve_checkout_session, opts[:connect_account], fn ->
        impl().retrieve_checkout_session(id, opts)
      end)
    )
  end

  @spec retrieve_payment_intent(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def retrieve_payment_intent(id, opts \\ []) do
    normalise_read(
      Telemetry.span_stripe(:retrieve_payment_intent, opts[:connect_account], fn ->
        impl().retrieve_payment_intent(id, opts)
      end)
    )
  end

  @spec retrieve_charge(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def retrieve_charge(id, opts \\ []) do
    normalise_read(
      Telemetry.span_stripe(:retrieve_charge, opts[:connect_account], fn ->
        impl().retrieve_charge(id, opts)
      end)
    )
  end

  @spec expire_checkout_session(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def expire_checkout_session(session_id, opts \\ []) do
    Telemetry.span_stripe(:expire_checkout_session, opts[:connect_account], fn ->
      impl().expire_checkout_session(session_id, opts)
    end)
  end

  @spec create_refund(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_refund(params, opts \\ []) do
    Telemetry.span_stripe(:create_refund, opts[:connect_account], fn ->
      impl().create_refund(params, opts)
    end)
  end

  @spec construct_webhook_event(binary(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def construct_webhook_event(payload, signature, secret),
    do: impl().construct_webhook_event(payload, signature, secret)

  # Normalise the success payload of a *read* response to a string-keyed map.
  #
  # Production stripity_stripe returns atom-keyed structs (`%Stripe.Account{}`,
  # `%Stripe.Checkout.Session{}`, …) from `retrieve_*`/`list_*`, whereas every
  # downstream consumer (workers, webhook handlers, `apply_account_event/2`)
  # expects the same string-keyed shape that `construct_webhook_event/3`
  # produces. Normalising here — at the single seam every read flows through —
  # means the rest of the pipeline never has to care which adapter (real or
  # Mox stub) produced the value. Normalisation is idempotent: a map that is
  # already string-keyed passes through unchanged.
  defp normalise_read({:ok, value}), do: {:ok, normalise(value)}
  defp normalise_read({:error, _reason} = err), do: err

  @doc false
  @spec normalise(term()) :: term()
  def normalise(value) when is_struct(value) do
    value
    |> Map.from_struct()
    |> Enum.map(fn {k, v} -> {to_string(k), normalise(v)} end)
    |> Map.new()
  end

  def normalise(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {to_string(k), normalise(v)} end)
    |> Map.new()
  end

  def normalise(value) when is_list(value), do: Enum.map(value, &normalise/1)
  def normalise(value), do: value

  defp impl, do: Application.get_env(:tymeslot, :stripe_adapter, __MODULE__.Stripity)
end

defmodule Tymeslot.MeetingPayments.StripeAdapter.Stripity do
  @moduledoc """
  Production implementation: passes through to stripity_stripe.

  Connect endpoints take a `connect_account` opt that becomes the
  `Stripe-Account` request header. For `retrieve_account/1` the
  account ID is forwarded as `connect_account` because stripity_stripe
  v3's `Stripe.Account.retrieve/2` retrieves the account scoped to the
  current API key — the only way to fetch a connected account is via
  the `Stripe-Account` header.
  """

  @behaviour Tymeslot.MeetingPayments.StripeAdapter

  alias Stripe.Account
  alias Stripe.AccountLink
  alias Stripe.Charge
  alias Stripe.Checkout.Session, as: CheckoutSession
  alias Stripe.PaymentIntent
  alias Stripe.Refund
  alias Stripe.Webhook
  alias Tymeslot.MeetingPayments.StripeAdapter

  @impl StripeAdapter
  def create_account(params, opts), do: Account.create(params, opts)

  @impl StripeAdapter
  def retrieve_account(id), do: Account.retrieve(%{}, connect_account: id)

  @impl StripeAdapter
  def create_account_link(params), do: AccountLink.create(params)

  @impl StripeAdapter
  def create_checkout_session(params, opts), do: CheckoutSession.create(params, opts)

  @impl StripeAdapter
  def retrieve_checkout_session(id, opts), do: CheckoutSession.retrieve(id, %{}, opts)

  @impl StripeAdapter
  def retrieve_payment_intent(id, opts),
    do: PaymentIntent.retrieve(id, %{expand: ["latest_charge"]}, opts)

  @impl StripeAdapter
  def retrieve_charge(id, opts), do: Charge.retrieve(id, %{}, opts)

  @impl StripeAdapter
  def expire_checkout_session(session_id, opts),
    do: CheckoutSession.expire(session_id, %{}, opts)

  @impl StripeAdapter
  def create_refund(params, opts), do: Refund.create(params, opts)

  @impl StripeAdapter
  def construct_webhook_event(payload, signature, secret) do
    case Webhook.construct_event(payload, signature, secret) do
      # Stripity returns a struct; normalise to a string-keyed map so the rest
      # of the pipeline doesn't depend on stripity-internal layout. Shares the
      # same recursive normaliser as the read responses.
      {:ok, event} -> {:ok, StripeAdapter.normalise(event)}
      {:error, _reason} = err -> err
    end
  end
end
