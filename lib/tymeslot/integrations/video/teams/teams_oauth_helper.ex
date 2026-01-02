defmodule Tymeslot.Integrations.Video.Teams.TeamsOAuthHelper do
  @moduledoc """
  Helper module for Microsoft Teams OAuth flow for video integrations.

  This module provides functions to generate OAuth URLs and handle
  the OAuth callback for Microsoft Graph API integration specifically
  for Teams meeting creation.
  """

  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Common.OAuth.State
  alias Tymeslot.Integrations.Common.OAuth.TokenExchange

  require Logger

  @teams_scope "https://graph.microsoft.com/OnlineMeetings.ReadWrite"
  @oauth_base_url "https://login.microsoftonline.com/common/oauth2/v2.0"
  @token_url "#{@oauth_base_url}/token"

  @doc """
  Generates the OAuth authorization URL for Microsoft Teams.
  """
  @spec authorization_url(term(), String.t()) :: String.t()
  def authorization_url(user_id, redirect_uri) do
    state = generate_state(user_id)

    params = %{
      client_id: teams_client_id(),
      redirect_uri: redirect_uri,
      response_type: "code",
      scope: @teams_scope,
      state: state,
      response_mode: "query",
      prompt: "select_account"
    }

    query_string = URI.encode_query(params)
    "#{@oauth_base_url}/authorize?" <> query_string
  end

  @doc """
  Exchanges authorization code for access and refresh tokens.
  """
  @spec exchange_code_for_tokens(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def exchange_code_for_tokens(code, redirect_uri, state) do
    with {:ok, user_id} <- verify_state(state),
         {:ok, tokens} <- fetch_tokens(code, redirect_uri) do
      {:ok, Map.put(tokens, :user_id, user_id)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Refreshes an access token using the refresh token.
  """
  @spec refresh_access_token(String.t()) :: {:ok, map()} | {:error, String.t()}
  def refresh_access_token(refresh_token) do
    body = %{
      refresh_token: refresh_token,
      client_id: teams_client_id(),
      client_secret: teams_client_secret(),
      grant_type: "refresh_token",
      scope: @teams_scope
    }

    case TokenExchange.refresh_access_token(@token_url, body,
           fallback_refresh_token: refresh_token,
           fallback_scope: @teams_scope
         ) do
      {:ok, tokens} ->
        {:ok, tokens}

      {:error, {:http_error, status, body}} ->
        Logger.error("Teams OAuth token refresh failed",
          status: status,
          response_body: Redactor.redact_and_truncate(body)
        )

        {:error, "Token refresh failed: HTTP #{status} (see logs for details)"}

      {:error, {:network_error, reason}} ->
        Logger.error("Network error during Teams token refresh", reason: inspect(reason))
        {:error, "Network error during token refresh: #{inspect(reason)}"}
    end
  end

  @doc """
  Validates if a token is still valid or needs refresh.
  """
  @spec validate_token(map()) :: {:ok, :valid | :needs_refresh} | {:error, String.t()}
  def validate_token(config) do
    case Map.get(config, :token_expires_at) do
      nil ->
        {:error, "No token expiration information"}

      expires_at ->
        # Consider token expired if it expires within 5 minutes
        buffer_time = DateTime.add(DateTime.utc_now(), 300, :second)

        if DateTime.compare(expires_at, buffer_time) == :gt do
          {:ok, :valid}
        else
          {:ok, :needs_refresh}
        end
    end
  end

  # Private functions

  defp fetch_tokens(code, redirect_uri) do
    TokenExchange.exchange_code_for_tokens(
      code,
      redirect_uri,
      @token_url,
      teams_client_id(),
      teams_client_secret(),
      @teams_scope
    )
  end

  defp generate_state(user_id) do
    State.generate(user_id, state_secret())
  end

  defp verify_state(state) when is_binary(state) do
    State.validate(state, state_secret())
  end

  defp verify_state(_), do: {:error, "Invalid state parameter"}

  defp teams_client_id do
    # Reuse Outlook OAuth credentials since both use Microsoft Graph API
    Application.get_env(:tymeslot, :outlook_oauth)[:client_id] ||
      System.get_env("OUTLOOK_CLIENT_ID") ||
      raise "Outlook Client ID not configured"
  end

  defp teams_client_secret do
    # Reuse Outlook OAuth credentials since both use Microsoft Graph API
    Application.get_env(:tymeslot, :outlook_oauth)[:client_secret] ||
      System.get_env("OUTLOOK_CLIENT_SECRET") ||
      raise "Outlook Client Secret not configured"
  end

  defp state_secret do
    # Reuse Outlook OAuth state secret
    Application.get_env(:tymeslot, :outlook_oauth)[:state_secret] ||
      System.get_env("OUTLOOK_STATE_SECRET") ||
      raise "Outlook State Secret not configured"
  end
end
