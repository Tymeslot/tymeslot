defmodule Tymeslot.Auth.OAuth.Client do
  @moduledoc """
  The HTTP side of social sign-in: the authorise URL, the code exchange, and
  authenticated requests to the provider's API. What differs per provider
  comes from `Tymeslot.Auth.OAuth.Providers`.

  Requests go through `Tymeslot.Infrastructure.HTTPClient` directly rather
  than the swappable `:http_client_module`: the provider is the boundary, and
  tests stub it with `Req.Test`, which that client already routes to.
  """

  alias Tymeslot.Auth.OAuth.Providers
  alias Tymeslot.Infrastructure.HTTPClient

  require Logger

  @user_agent "Tymeslot-Scheduler"

  @type provider :: Providers.provider()
  @type error :: {:provider_rejected, term()} | {:transport, term()} | {:invalid_response, term()}

  @doc """
  The URL that starts the flow at the provider, carrying the state and the
  PKCE code challenge.
  """
  @spec authorize_url(provider(), String.t(), %{state: String.t(), code_challenge: String.t()}) ::
          String.t()
  def authorize_url(provider, redirect_uri, %{state: state, code_challenge: challenge}) do
    config = Providers.config(provider)

    query =
      Map.merge(Providers.fetch!(provider).authorize_params, %{
        response_type: "code",
        client_id: config.client_id,
        redirect_uri: redirect_uri,
        scope: config.scope,
        state: state,
        code_challenge: challenge,
        code_challenge_method: "S256"
      })

    config.authorize_url <> "?" <> URI.encode_query(query)
  end

  @doc """
  Exchanges the authorisation code for an access token, proving possession
  of the PKCE code verifier.

  The client authenticates with HTTP Basic and also names itself in the
  body, which every provider here accepts.
  """
  @spec exchange_code(provider(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, error()}
  def exchange_code(provider, code, code_verifier, redirect_uri) do
    config = Providers.config(provider)

    body =
      URI.encode_query(%{
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri,
        client_id: config.client_id,
        code_verifier: code_verifier
      })

    headers = [
      {"Authorization", "Basic " <> Base.encode64("#{config.client_id}:#{config.client_secret}")},
      {"Content-Type", "application/x-www-form-urlencoded"}
    ]

    case request(:post, config.token_url, body, headers) do
      {:ok, %{"access_token" => token}} when is_binary(token) and token != "" ->
        {:ok, token}

      # GitHub answers a bad or reused code with 200 and an `error` field.
      {:ok, %{} = response} ->
        {:error, {:provider_rejected, Map.get(response, "error", :no_access_token)}}

      {:ok, _not_an_object} ->
        {:error, {:invalid_response, :not_an_object}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  The signed-in user's profile from the provider's userinfo endpoint.
  """
  @spec fetch_userinfo(provider(), String.t()) :: {:ok, map()} | {:error, error()}
  def fetch_userinfo(provider, token) do
    case get(provider, Providers.config(provider).userinfo_url, token) do
      {:ok, %{} = user_info} -> {:ok, user_info}
      {:ok, _not_an_object} -> {:error, {:invalid_response, :not_an_object}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  An authenticated GET against the provider's API, decoded from JSON.
  """
  @spec get(provider(), String.t(), String.t()) :: {:ok, term()} | {:error, error()}
  def get(provider, url, token) do
    authorization = "#{Providers.fetch!(provider).auth_scheme} #{token}"
    request(:get, url, "", [{"Authorization", authorization}])
  end

  defp request(method, url, body, headers) do
    headers = [{"User-Agent", @user_agent}, {"Accept", "application/json"} | headers]

    case HTTPClient.request(method, url, body, headers) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        decode(body)

      {:ok, %{status: status}} ->
        Logger.warning("OAuth provider refused a request",
          origin: HTTPClient.log_safe_origin(url),
          status: status
        )

        {:error, {:provider_rejected, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _decode_error} -> {:error, {:invalid_response, :not_json}}
    end
  end
end
