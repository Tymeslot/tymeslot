defmodule Tymeslot.Integrations.Common.OAuth.TokenExchange do
  @moduledoc """
  Shared OAuth token utility functions used across integrations.

  Provides helpers for exchanging authorization codes as well as refreshing access tokens
  against OAuth token endpoints (Google, Microsoft, etc.).
  """

  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Infrastructure.Logging.Redactor

  require Logger

  @default_headers [{"Content-Type", "application/x-www-form-urlencoded"}]

  @doc """
  Exchanges an authorization code for access and refresh tokens.

  ## Parameters
  - `code`: The authorization code from OAuth callback
  - `redirect_uri`: The redirect URI used in the authorization request
  - `token_url`: The OAuth token endpoint URL
  - `client_id`: OAuth client ID
  - `client_secret`: OAuth client secret
  - `scope`: OAuth scope string

  ## Returns
  - `{:ok, %{access_token: String.t(), refresh_token: String.t(), expires_at: DateTime.t(), scope: String.t()}}`
  - `{:error, String.t()}` on failure
  """
  @spec exchange_code_for_tokens(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) ::
          {:ok, map()} | {:error, String.t()}
  def exchange_code_for_tokens(code, redirect_uri, token_url, client_id, client_secret, scope) do
    body = %{
      code: code,
      client_id: client_id,
      client_secret: client_secret,
      redirect_uri: redirect_uri,
      grant_type: "authorization_code",
      scope: scope
    }

    case http_client().request(:post, token_url, URI.encode_query(body), @default_headers, []) do
      {:ok, response} ->
        %{status_code: status, body: resp_body} = normalize_response(response)

        case status do
          200 ->
            parse_token_response(resp_body)

          _ ->
            Logger.error("OAuth token exchange failed",
              status: status,
              response_body: Redactor.redact_and_truncate(resp_body)
            )

            {:error, "OAuth token exchange failed: HTTP #{status} (see logs for details)"}
        end

      {:error, reason} ->
        Logger.error("Network error during token exchange", reason: inspect(reason))
        {:error, "Network error during token exchange: #{inspect(reason)}"}
    end
  end

  @doc """
  Refreshes an access token using a refresh token payload.

  Returns {:ok, tokens} with the same structure as `exchange_code_for_tokens/6`.
  """
  @spec refresh_access_token(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, {:http_error, integer(), String.t()} | {:network_error, any()}}
  def refresh_access_token(token_url, body, opts \\ []) do
    fallback_refresh_token = Keyword.get(opts, :fallback_refresh_token)
    fallback_scope = Keyword.get(opts, :fallback_scope)
    headers = Keyword.get(opts, :headers, @default_headers)

    case http_client().request(:post, token_url, URI.encode_query(body), headers, []) do
      {:ok, response} ->
        %{status_code: status, body: resp_body} = normalize_response(response)

        case status do
          200 ->
            parse_token_response(resp_body, fallback_refresh_token, fallback_scope)

          _ ->
            Logger.error("OAuth token refresh failed",
              status: status,
              response_body: Redactor.redact_and_truncate(resp_body)
            )

            {:error, {:http_error, status, "OAuth token refresh failed (see logs for details)"}}
        end

      {:error, reason} ->
        Logger.error("Network error during token refresh", reason: inspect(reason))
        {:error, {:network_error, reason}}
    end
  end

  # Private helpers

  defp http_client do
    Application.get_env(:tymeslot, :http_client_module, HTTPClient)
  end

  defp parse_token_response(response_body, fallback_refresh_token \\ nil, fallback_scope \\ nil) do
    response = Jason.decode!(response_body)
    expires_at = DateTime.add(DateTime.utc_now(), response["expires_in"], :second)

    {:ok,
     %{
       access_token: response["access_token"],
       refresh_token: response["refresh_token"] || fallback_refresh_token,
       expires_at: expires_at,
       scope: response["scope"] || fallback_scope
     }}
  end

  defp normalize_response(%{status_code: _status} = resp), do: resp
end
