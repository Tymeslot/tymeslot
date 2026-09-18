defmodule Tymeslot.Integrations.Common.OAuth.TokenExchange do
  @moduledoc """
  Shared OAuth token utility functions used across integrations.

  Provides helpers for exchanging authorization codes as well as refreshing access tokens
  against OAuth token endpoints (Google, Microsoft, etc.).
  """

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.Redactor

  require Logger

  @default_headers [{"Content-Type", "application/x-www-form-urlencoded"}]

  # The only keys a caller may add to a token log line. Deliberately narrow:
  # enough to attribute a failure to an integration, and nothing that could
  # carry a credential. See `refresh_access_token/3`.
  @log_context_keys [:integration_id, :user_id, :provider, :correlation_id]

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
          String.t(),
          keyword()
        ) ::
          {:ok, map()} | {:error, String.t()}
  def exchange_code_for_tokens(
        code,
        redirect_uri,
        token_url,
        client_id,
        client_secret,
        scope,
        opts \\ []
      ) do
    body = %{
      code: code,
      client_id: client_id,
      client_secret: client_secret,
      redirect_uri: redirect_uri,
      grant_type: "authorization_code",
      scope: scope
    }

    body =
      if Keyword.get(opts, :omit_body_credentials, false) do
        Map.drop(body, [:client_id, :client_secret])
      else
        body
      end

    headers = Keyword.get(opts, :headers, @default_headers)

    case Config.http_client_module().request(
           :post,
           token_url,
           URI.encode_query(body),
           headers,
           []
         ) do
      {:ok, response} ->
        %{status: status, body: resp_body} = normalize_response(response)

        case status do
          200 ->
            parse_token_response(resp_body, nil, scope)

          _other ->
            redacted_body = Redactor.redact_and_truncate(resp_body)

            Logger.error("OAuth token exchange failed",
              status: status,
              body: redacted_body
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

  ## Options

    * `:log_context` — key/value pairs merged into the failure log lines so a
      refresh failure can be attributed without joining against neighbouring
      lines. This is the shared refresh helper for every provider, so without
      it a failure line says only which status came back.

  Only `:integration_id`, `:user_id`, `:provider` and `:correlation_id` are
  kept; anything else is dropped rather than widening the line. Pass ids, never
  the integration struct: it carries the encrypted OAuth credentials, and the
  response body is redacted at this call site precisely so they stay out of the
  logs.
  """
  @spec refresh_access_token(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, {:http_error, integer(), String.t()} | {:network_error, any()}}
  def refresh_access_token(token_url, body, opts \\ []) do
    fallback_refresh_token = Keyword.get(opts, :fallback_refresh_token)
    fallback_scope = Keyword.get(opts, :fallback_scope)
    headers = Keyword.get(opts, :headers, @default_headers)
    log_context = log_context(opts)

    case Config.http_client_module().request(
           :post,
           token_url,
           URI.encode_query(body),
           headers,
           []
         ) do
      {:ok, response} ->
        %{status: status, body: resp_body} = normalize_response(response)

        case status do
          200 ->
            parse_token_response(resp_body, fallback_refresh_token, fallback_scope)

          _other ->
            Logger.error(
              "OAuth token refresh failed",
              log_context ++
                [status: status, body: Redactor.redact_and_truncate(resp_body)]
            )

            # Preserve the raw response body so callers can extract the OAuth
            # error type (e.g. `invalid_grant`) and route revoked-token failures
            # straight to the reauth flow instead of waiting on retry backoff.
            {:error, {:http_error, status, resp_body}}
        end

      {:error, reason} ->
        Logger.error(
          "Network error during token refresh",
          log_context ++ [reason: inspect(reason)]
        )

        {:error, {:network_error, reason}}
    end
  end

  # Private helpers

  # The allowed-key list is the contract, not a formality: a caller cannot
  # widen the log line, and cannot leak a credential by naming a key that is
  # not on it. Nils are dropped so a caller with only part of the context does
  # not emit `integration_id: nil`.
  defp log_context(opts) do
    opts
    |> Keyword.get(:log_context, [])
    |> Enum.filter(fn {key, value} -> key in @log_context_keys and not is_nil(value) end)
  end

  defp parse_token_response(response_body, fallback_refresh_token, fallback_scope) do
    case Jason.decode(response_body) do
      {:ok, response} ->
        expires_in = if is_integer(response["expires_in"]), do: response["expires_in"], else: 3600
        expires_at = DateTime.add(DateTime.utc_now(), expires_in, :second)

        {:ok,
         %{
           access_token: response["access_token"],
           refresh_token: response["refresh_token"] || fallback_refresh_token,
           id_token: response["id_token"],
           expires_at: expires_at,
           scope: response["scope"] || fallback_scope
         }}

      {:error, _decode_error} ->
        {:error, {:http_error, 200, "Invalid JSON response from token endpoint"}}
    end
  end

  defp normalize_response(%{status: _status} = resp), do: resp
end
