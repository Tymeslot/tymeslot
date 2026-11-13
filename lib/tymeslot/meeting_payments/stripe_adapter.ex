defmodule Tymeslot.MeetingPayments.StripeAdapter do
  @moduledoc """
  Single seam for every Stripe API call made by the meeting_payments
  context. The default implementation passes most calls through to
  stripity_stripe (the OAuth calls go straight through `HTTPClient`, see
  `Stripity`); tests replace it with a Mox stub via the
  `:tymeslot, :stripe_adapter` config.

  Every call is wrapped in `Tymeslot.MeetingPayments.Telemetry.span_stripe/3`
  so dashboards can chart per-operation latency and error rate.
  """

  alias Tymeslot.MeetingPayments.Telemetry

  @callback retrieve_account(account_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
  # `{:error, :oauth_failed}` means the outcome is unknown: Stripe may or may
  # not have consumed the code. The code must never be resent.
  @callback exchange_oauth_code(code :: String.t()) ::
              {:ok, %{stripe_user_id: String.t()}}
              | {:error, :invalid_grant | :oauth_failed}
  # `:controlled_account` is Stripe refusing for good to revoke an account the
  # platform controls; retrying cannot change it.
  @callback deauthorize_account(stripe_account_id :: String.t()) ::
              :ok | {:error, :not_connected | :controlled_account | :oauth_failed}
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

  @spec retrieve_account(String.t()) :: {:ok, map()} | {:error, term()}
  def retrieve_account(id) do
    normalise_read(
      Telemetry.span_stripe(:retrieve_account, id, fn -> impl().retrieve_account(id) end)
    )
  end

  @spec exchange_oauth_code(String.t()) ::
          {:ok, %{stripe_user_id: String.t()}} | {:error, :invalid_grant | :oauth_failed}
  def exchange_oauth_code(code) do
    Telemetry.span_stripe(:exchange_oauth_code, nil, fn -> impl().exchange_oauth_code(code) end)
  end

  @spec deauthorize_account(String.t()) ::
          :ok | {:error, :not_connected | :controlled_account | :oauth_failed}
  def deauthorize_account(stripe_account_id) do
    Telemetry.span_stripe(:deauthorize_account, stripe_account_id, fn ->
      impl().deauthorize_account(stripe_account_id)
    end)
  end

  @spec create_checkout_session(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_checkout_session(params, opts) do
    Telemetry.span_stripe(:create_checkout_session, opts[:connect_account], fn ->
      impl().create_checkout_session(params, opts)
    end)
  end

  @spec retrieve_checkout_session(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def retrieve_checkout_session(id, opts) do
    normalise_read(
      Telemetry.span_stripe(:retrieve_checkout_session, opts[:connect_account], fn ->
        impl().retrieve_checkout_session(id, opts)
      end)
    )
  end

  @spec retrieve_payment_intent(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def retrieve_payment_intent(id, opts) do
    normalise_read(
      Telemetry.span_stripe(:retrieve_payment_intent, opts[:connect_account], fn ->
        impl().retrieve_payment_intent(id, opts)
      end)
    )
  end

  @spec retrieve_charge(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def retrieve_charge(id, opts) do
    normalise_read(
      Telemetry.span_stripe(:retrieve_charge, opts[:connect_account], fn ->
        impl().retrieve_charge(id, opts)
      end)
    )
  end

  @spec expire_checkout_session(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def expire_checkout_session(session_id, opts) do
    Telemetry.span_stripe(:expire_checkout_session, opts[:connect_account], fn ->
      impl().expire_checkout_session(session_id, opts)
    end)
  end

  @spec create_refund(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_refund(params, opts) do
    Telemetry.span_stripe(:create_refund, opts[:connect_account], fn ->
      impl().create_refund(params, opts)
    end)
  end

  # Normalise the success payload of a *read* response to a string-keyed map.
  #
  # Production stripity_stripe returns atom-keyed structs (`%Stripe.Account{}`,
  # `%Stripe.Checkout.Session{}`, …) from `retrieve_*`/`list_*`, whereas every
  # downstream consumer (workers, webhook handlers, `apply_account_event/2`)
  # expects the same string-keyed shape a webhook event arrives in.
  # Normalising here, at the single seam every read flows through, means
  # the rest of the pipeline never has to care which adapter (real or Mox
  # stub) produced the value. Normalisation is idempotent: a map that is
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
  Production implementation: passes through to stripity_stripe, except for the
  two Connect OAuth calls, which use `HTTPClient` directly (see below).

  Connect endpoints take a `connect_account` opt that becomes the
  `Stripe-Account` request header. For `retrieve_account/1` the
  account ID is forwarded as `connect_account` because stripity_stripe
  v3's `Stripe.Account.retrieve/2` retrieves the account scoped to the
  current API key — the only way to fetch a connected account is via
  the `Stripe-Account` header.
  """

  @behaviour Tymeslot.MeetingPayments.StripeAdapter

  require Logger

  alias Stripe.Account
  alias Stripe.Charge
  alias Stripe.Checkout.Session, as: CheckoutSession
  alias Stripe.PaymentIntent
  alias Stripe.Refund
  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.Payments.Config, as: PaymentsConfig

  @oauth_token_url "https://connect.stripe.com/oauth/token"
  @oauth_deauthorize_url "https://connect.stripe.com/oauth/deauthorize"

  # `redirect: false` keeps the credentials (and a code) from following a 3xx.
  @oauth_options [
    receive_timeout: 15_000,
    request_timeout: 20_000,
    connect_options: [timeout: 5_000],
    redirect: false
  ]

  @impl StripeAdapter
  def retrieve_account(id), do: Account.retrieve(%{}, connect_account: id)

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

  # Stripe's OAuth endpoints are not idempotent: consuming an authorisation
  # code twice revokes the connection. So these calls bypass stripity_stripe
  # (which adds idempotency headers and retries POSTs) and go through
  # HTTPClient, which never retries. The request body and the response are
  # never logged or kept: the token response carries live credentials and
  # `error_description` can echo the code.
  @impl StripeAdapter
  def exchange_oauth_code(code) do
    form = %{"grant_type" => "authorization_code", "code" => code}

    case oauth_post(:exchange_oauth_code, @oauth_token_url, form) do
      {:ok, 200, %{"stripe_user_id" => id}} when is_binary(id) -> {:ok, %{stripe_user_id: id}}
      {:ok, _status, %{"error" => "invalid_grant"}} -> {:error, :invalid_grant}
      _other -> {:error, :oauth_failed}
    end
  end

  @impl StripeAdapter
  def deauthorize_account(stripe_account_id) do
    form = %{
      "client_id" => Application.get_env(:tymeslot, :stripe_connect_client_id),
      "stripe_user_id" => stripe_account_id
    }

    case oauth_post(:deauthorize_account, @oauth_deauthorize_url, form) do
      {:ok, status, body} -> revocation_result(status, body, stripe_account_id)
      :error -> {:error, :oauth_failed}
    end
  end

  defp revocation_result(200, %{"stripe_user_id" => id}, id), do: :ok

  defp revocation_result(_status, %{"error" => "no_deauth_on_controlled_account"}, _id),
    do: {:error, :controlled_account}

  defp revocation_result(_status, %{"error" => "invalid_client", "error_description" => d}, _id)
       when is_binary(d),
       do: classify_invalid_client(String.downcase(d))

  defp revocation_result(_status, _body, _id), do: {:error, :oauth_failed}

  # `invalid_client` also covers a foreign client ID, a key/client-ID mode
  # mismatch and an account the platform controls; only the description tells
  # them apart. Anything unrecognised stays `:oauth_failed`, which is retried.
  defp classify_invalid_client(description) do
    cond do
      description =~ "not connected" or description =~ "does not exist" ->
        {:error, :not_connected}

      description =~ "controlled" ->
        {:error, :controlled_account}

      true ->
        {:error, :oauth_failed}
    end
  end

  # Returns `{:ok, status, decoded_map}`, or `:error`. The only things logged
  # on a non-success path are the operation, the status, Stripe's `error` code
  # and a transport exception's reason atom.
  defp oauth_post(operation, url, form) do
    headers = [
      {"Authorization", "Basic " <> Base.encode64("#{platform_key()}:")},
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Accept", "application/json"}
    ]

    case HTTPClient.post(url, URI.encode_query(form), headers, @oauth_options) do
      {:ok, %{status: status, body: body}} ->
        decoded = decode_body(body)
        log_unless_success(operation, status, decoded)
        {:ok, status, decoded}

      {:error, reason} ->
        Logger.warning("Stripe OAuth request failed",
          operation: operation,
          reason: transport_reason(reason)
        )

        :error
    end
  end

  defp log_unless_success(_operation, 200, %{"stripe_user_id" => id}) when is_binary(id), do: :ok

  defp log_unless_success(operation, status, decoded) do
    Logger.warning("Stripe OAuth request was not accepted",
      operation: operation,
      status: status,
      error: stripe_error_code(decoded)
    )
  end

  defp stripe_error_code(%{"error" => code}) when is_binary(code), do: code
  defp stripe_error_code(_decoded), do: nil

  defp transport_reason(%{reason: reason}) when is_atom(reason), do: reason
  defp transport_reason(_reason), do: :unknown

  # `HTTPClient` always returns the body as a binary.
  defp decode_body(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> decoded
      _other -> %{}
    end
  end

  defp platform_key, do: PaymentsConfig.stripe_api_key()
end
