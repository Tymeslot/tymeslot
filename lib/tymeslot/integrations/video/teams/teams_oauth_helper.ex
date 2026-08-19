defmodule Tymeslot.Integrations.Video.Teams.TeamsOAuthHelper do
  @moduledoc """
  Helper module for Microsoft Teams OAuth flow for video integrations.

  This module provides functions to generate OAuth URLs and handle
  the OAuth callback   for Microsoft Graph API integration specifically
  for Teams meeting creation.
  """

  @behaviour Tymeslot.Integrations.Video.Teams.TeamsOAuthHelperBehaviour

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Infrastructure.Retry
  alias Tymeslot.Integrations.Common.OAuth.ErrorParser
  alias Tymeslot.Integrations.Common.OAuth.IdToken
  alias Tymeslot.Integrations.Common.OAuth.State
  alias Tymeslot.Integrations.Common.OAuth.TokenExchange
  alias Tymeslot.Integrations.Shared.MicrosoftConfig
  alias Tymeslot.Integrations.Shared.OAuth.ProviderHelpers
  alias Tymeslot.Integrations.Video.OAuthTokenManager

  require Logger

  @teams_scope "https://graph.microsoft.com/Calendars.ReadWrite https://graph.microsoft.com/User.Read offline_access openid profile email"

  @oauth_base_url "https://login.microsoftonline.com/common/oauth2/v2.0"
  @token_url "#{@oauth_base_url}/token"

  @doc """
  Generates the OAuth authorization URL for Microsoft Teams.
  """
  @spec authorization_url(term(), String.t(), keyword()) :: String.t()
  def authorization_url(user_id, redirect_uri, options \\ []) do
    integration_id = Keyword.get(options, :integration_id)
    login_hint = Keyword.get(options, :login_hint)
    state = generate_state(user_id, integration_id)

    params = %{
      client_id: MicrosoftConfig.client_id(),
      redirect_uri: redirect_uri,
      response_type: "code",
      scope: @teams_scope,
      state: state,
      response_mode: "query",
      prompt: "select_account"
    }

    url =
      ProviderHelpers.build_authorization_url("#{@oauth_base_url}/authorize", params, login_hint)

    Logger.info("Generated Teams OAuth URL", scope: @teams_scope)
    url
  end

  @doc """
  Exchanges authorization code for access and refresh tokens.
  Also fetches the user profile to get the Microsoft user ID and tenant ID.
  """
  @spec exchange_code_for_tokens(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  # credo:disable-for-next-line Credo.Check.Design.DuplicatedCode
  def exchange_code_for_tokens(code, redirect_uri, state) do
    with {:ok, %{user_id: user_id, integration_id: integration_id}} <- verify_state(state),
         {:ok, tokens} <- fetch_tokens(code, redirect_uri),
         :ok <- verify_required_scopes(tokens),
         {:ok, profile} <- fetch_user_profile(tokens.access_token) do
      {:ok, build_result_tokens(tokens, user_id, integration_id, profile)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_result_tokens(tokens, user_id, integration_id, profile) do
    id_claims = decode_id_claims(tokens, user_id)

    Map.merge(tokens, %{
      user_id: user_id,
      integration_id: integration_id,
      teams_user_id: profile["id"],
      tenant_id: id_claims.tid || profile["tenant_id"] || "common",
      provider_account_id: id_claims.oid || profile["id"],
      provider_account_email: id_claims.email || profile["mail"],
      scope: ensure_calendar_scope(tokens)
    })
  end

  defp decode_id_claims(tokens, user_id) do
    case IdToken.decode(tokens[:id_token]) do
      {:ok, claims} ->
        claims

      {:error, reason} ->
        if tokens[:id_token] do
          Logger.warning(
            "Failed to decode Teams id_token — account dedup falling back to profile data",
            user_id: user_id,
            reason: inspect(reason)
          )
        end

        %{oid: nil, email: nil, tid: nil}
    end
  end

  defp ensure_calendar_scope(tokens) do
    returned_scope = tokens[:scope] || ""

    if String.contains?(returned_scope, "Calendars.ReadWrite"),
      do: returned_scope,
      else: @teams_scope
  end

  defp fetch_user_profile(token) do
    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"}
    ]

    Retry.with_backoff(fn ->
      case Config.http_client_module().get("https://graph.microsoft.com/v1.0/me", headers, []) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"id" => id} = profile} when is_binary(id) and id != "" ->
              {:ok, profile}

            {:ok, _result} ->
              {:error, "Microsoft profile missing unique ID"}

            {:error, _reason} ->
              {:error, "Invalid JSON response from Microsoft profile API"}
          end

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.error("Failed to fetch Microsoft user profile",
            status: status,
            body: Redactor.redact_and_truncate(body)
          )

          {:error, "Failed to fetch user profile: HTTP #{status}"}

        {:error, exception} when is_exception(exception) ->
          {:error, "Network error fetching profile: #{Exception.message(exception)}"}

        {:error, reason} ->
          {:error, "Network error fetching profile: #{inspect(reason)}"}
      end
    end)
  end

  @doc """
  Refreshes an access token using the refresh token.
  """
  @spec refresh_access_token(String.t(), String.t() | nil) :: {:ok, map()} | {:error, String.t()}
  def refresh_access_token(refresh_token, current_scope \\ nil) do
    scope = current_scope || @teams_scope

    body = %{
      refresh_token: refresh_token,
      client_id: MicrosoftConfig.client_id(),
      client_secret: MicrosoftConfig.client_secret(),
      grant_type: "refresh_token",
      scope: scope
    }

    case TokenExchange.refresh_access_token(@token_url, body,
           fallback_refresh_token: refresh_token,
           fallback_scope: scope
         ) do
      {:ok, tokens} ->
        {:ok, tokens}

      {:error, {:http_error, status, body}} ->
        Logger.error("Teams OAuth token refresh failed",
          status: status,
          response_body: Redactor.redact_and_truncate(body)
        )

        {:error, ErrorParser.build_message("Token refresh failed", status, body)}

      {:error, {:network_error, reason}} ->
        Logger.error("Network error during Teams token refresh", reason: inspect(reason))
        {:error, "Network error during token refresh: #{inspect(reason)}"}
    end
  end

  @doc """
  Validates if a token is still valid or needs refresh.
  """
  @spec validate_token(%{optional(:token_expires_at) => DateTime.t()}) ::
          {:ok, :valid | :needs_refresh} | {:error, String.t()}
  def validate_token(config) do
    case Map.get(config, :token_expires_at) do
      nil ->
        {:error, "No token expiration information"}

      expires_at ->
        # The expiry buffer is a shared decision, not a per-provider one, and
        # `OAuthTokenManager`'s moduledoc claims ownership of it. Google Meet
        # already asks it; this used to carry its own copy of the number.
        if OAuthTokenManager.token_still_valid?(expires_at) do
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
      MicrosoftConfig.client_id(),
      MicrosoftConfig.client_secret(),
      @teams_scope
    )
  end

  defp generate_state(user_id, integration_id) do
    State.generate(user_id, MicrosoftConfig.state_secret(), integration_id)
  end

  defp verify_state(state) when is_binary(state) do
    State.validate(state, MicrosoftConfig.state_secret())
  end

  defp verify_state(_arg), do: {:error, "Invalid state parameter"}

  defp verify_required_scopes(tokens) do
    returned_scope = tokens[:scope] || ""

    if String.contains?(returned_scope, "Calendars.ReadWrite") do
      :ok
    else
      Logger.error("Microsoft OAuth response missing required scope: Calendars.ReadWrite",
        returned_scope: returned_scope
      )

      {:error, :missing_required_scope}
    end
  end
end
