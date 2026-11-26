defmodule Tymeslot.Integrations.Stripe.ConnectOAuth do
  @moduledoc """
  Stripe Connect OAuth: exchanging an authorisation code and deauthorising a
  connected account.

  Stripe's OAuth endpoints are not idempotent: consuming an authorisation
  code twice revokes the connection. So these calls never go through
  `Tymeslot.Integrations.Stripe.Client` (which adds idempotency keys and
  retries) but through `Infrastructure.HTTPClient`, which never retries. The
  request body and the response are never logged or kept: the token response
  carries live credentials and `error_description` can echo the code.

  Results: `exchange_code/1` gives `{:ok, %{stripe_user_id: id}}` or
  `{:error, :invalid_grant | :oauth_failed}`; `deauthorize/1` gives `:ok` or
  `{:error, :not_connected | :controlled_account | :oauth_failed}`.
  """

  require Logger

  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Integrations.Stripe

  @oauth_token_url "https://connect.stripe.com/oauth/token"
  @oauth_deauthorize_url "https://connect.stripe.com/oauth/deauthorize"

  # `redirect: false` keeps the credentials (and a code) from following a 3xx.
  @oauth_options [
    receive_timeout: 15_000,
    request_timeout: 20_000,
    connect_options: [timeout: 5_000],
    redirect: false
  ]

  @doc "Exchanges an authorisation code for the connected account's ID."
  @spec exchange_code(String.t()) ::
          {:ok, %{stripe_user_id: String.t()}} | {:error, :invalid_grant | :oauth_failed}
  def exchange_code(code) do
    form = %{"grant_type" => "authorization_code", "code" => code}

    case oauth_post(:exchange_oauth_code, @oauth_token_url, form) do
      {:ok, 200, %{"stripe_user_id" => id}} when is_binary(id) -> {:ok, %{stripe_user_id: id}}
      {:ok, _status, %{"error" => "invalid_grant"}} -> {:error, :invalid_grant}
      _other -> {:error, :oauth_failed}
    end
  end

  @doc "Revokes the platform's access to a connected account."
  @spec deauthorize(String.t()) ::
          :ok | {:error, :not_connected | :controlled_account | :oauth_failed}
  def deauthorize(stripe_account_id) do
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

  defp platform_key, do: Stripe.secret_key()
end
