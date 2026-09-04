defmodule Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelper do
  @moduledoc """
  Helper module for Zoom OAuth flow for video integrations.

  Provides functions to generate OAuth URLs and handle the OAuth callback for
  the Zoom REST API v2, used to create scheduled meetings on a connected user's
  Zoom account.

  ## Token endpoint authentication

  Zoom requires HTTP Basic Auth on the token endpoint
  (`Authorization: Basic base64(client_id:client_secret)`). The shared
  `Tymeslot.Integrations.Common.OAuth.TokenExchange` module accepts a `:headers`
  option that lets us thread that header through both the
  authorization-code exchange and the refresh-token flow without duplicating
  HTTP, JSON, retry, redaction, and logging plumbing here.
  """

  @behaviour Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelperBehaviour

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Infrastructure.Retry
  alias Tymeslot.Integrations.Common.OAuth.ErrorParser
  alias Tymeslot.Integrations.Common.OAuth.State
  alias Tymeslot.Integrations.Common.OAuth.TokenExchange
  alias Tymeslot.Integrations.Shared.OAuth.ProviderHelpers
  alias Tymeslot.Integrations.Shared.ZoomConfig
  alias Tymeslot.Integrations.Video.OAuthTokenManager
  alias Tymeslot.Integrations.Video.Providers.ZoomProvider.Scopes

  require Logger

  # Granular scopes are one per action, so each write Tymeslot performs has to
  # be asked for by name. `Scopes` owns which ones this deployment asks for and
  # why one of them is conditional; keeping the list there is what lets the
  # pre-flight tell "your grant is stale" apart from "this Zoom app cannot do
  # that at all".
  #
  # Resolved per call, not into a module attribute: the setting behind it is
  # read from the environment at boot, so freezing it at compile time would
  # bake one deployment's answer into every image.
  defp zoom_scope, do: Scopes.requested_scope()

  @authorize_url "https://zoom.us/oauth/authorize"
  @token_url "https://zoom.us/oauth/token"
  @user_profile_url "https://api.zoom.us/v2/users/me"

  @doc """
  Generates the OAuth authorization URL for Zoom.
  """
  @impl Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelperBehaviour
  @spec authorization_url(integer(), String.t()) :: String.t()
  def authorization_url(user_id, redirect_uri), do: authorization_url(user_id, redirect_uri, [])

  @impl Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelperBehaviour
  @spec authorization_url(integer(), String.t(), keyword()) :: String.t()
  def authorization_url(user_id, redirect_uri, options) do
    integration_id = Keyword.get(options, :integration_id)
    login_hint = Keyword.get(options, :login_hint)
    state = generate_state(user_id, integration_id)

    params = %{
      client_id: ZoomConfig.client_id(),
      redirect_uri: redirect_uri,
      response_type: "code",
      scope: zoom_scope(),
      state: state
    }

    url = ProviderHelpers.build_authorization_url(@authorize_url, params, login_hint)
    Logger.info("Generated Zoom OAuth URL", scope: zoom_scope())
    url
  end

  @doc """
  Exchanges authorization code for access and refresh tokens.

  Validates the signed state, exchanges the code, then fetches the Zoom user
  profile so the integration can be uniquely identified by the Zoom account ID.
  """
  @impl Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelperBehaviour
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

  @doc """
  Refreshes an access token using the refresh token.
  """
  @impl Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelperBehaviour
  @spec refresh_access_token(String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def refresh_access_token(refresh_token, current_scope \\ nil) do
    scope = current_scope || zoom_scope()

    body = %{
      grant_type: "refresh_token",
      refresh_token: refresh_token
    }

    with {:ok, headers} <- basic_auth_headers() do
      case TokenExchange.refresh_access_token(@token_url, body,
             fallback_refresh_token: refresh_token,
             fallback_scope: scope,
             headers: headers
           ) do
        {:ok, tokens} ->
          {:ok, tokens}

        {:error, {:http_error, status, resp_body}} ->
          Logger.error("Zoom OAuth token refresh failed",
            status: status,
            response_body: Redactor.redact_and_truncate(resp_body)
          )

          {:error, ErrorParser.build_message("Token refresh failed", status, resp_body)}

        {:error, {:network_error, reason}} ->
          Logger.error("Network error during Zoom token refresh", reason: inspect(reason))
          {:error, "Network error during token refresh: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Validates if a token is still valid or needs refresh.
  """
  @impl Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelperBehaviour
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

  # Private helpers

  defp build_result_tokens(tokens, user_id, integration_id, profile) do
    Map.merge(tokens, %{
      user_id: user_id,
      integration_id: integration_id,
      provider_account_id: profile["id"],
      provider_account_email: profile["email"],
      scope: tokens[:scope] || zoom_scope()
    })
  end

  defp fetch_tokens(code, redirect_uri) do
    with {:ok, client_id} <- ZoomConfig.fetch_client_id(),
         {:ok, client_secret} <- ZoomConfig.fetch_client_secret(),
         {:ok, headers} <- basic_auth_headers() do
      TokenExchange.exchange_code_for_tokens(
        code,
        redirect_uri,
        @token_url,
        client_id,
        client_secret,
        zoom_scope(),
        headers: headers,
        omit_body_credentials: true
      )
    end
  end

  defp fetch_user_profile(token) do
    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"}
    ]

    Retry.with_backoff(fn ->
      case Config.http_client_module().get(@user_profile_url, headers, []) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          parse_profile_body(body)

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.error("Failed to fetch Zoom user profile",
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

  defp parse_profile_body(body) do
    case Jason.decode(body) do
      {:ok, %{"id" => id} = profile} when is_binary(id) and id != "" ->
        {:ok, profile}

      {:ok, _other} ->
        {:error, "Zoom profile missing unique ID"}

      {:error, _reason} ->
        {:error, "Invalid JSON response from Zoom profile API"}
    end
  end

  defp basic_auth_headers do
    with {:ok, client_id} <- ZoomConfig.fetch_client_id(),
         {:ok, client_secret} <- ZoomConfig.fetch_client_secret() do
      credentials = Base.encode64("#{client_id}:#{client_secret}")

      {:ok,
       [
         {"Authorization", "Basic #{credentials}"},
         {"Content-Type", "application/x-www-form-urlencoded"}
       ]}
    end
  end

  defp verify_required_scopes(tokens) do
    returned_scope = tokens[:scope] || ""

    if String.contains?(returned_scope, "meeting:write:meeting") do
      :ok
    else
      Logger.error("Zoom OAuth response missing required scope",
        required_scope: "meeting:write:meeting",
        returned_scope: returned_scope
      )

      {:error, :missing_required_scope}
    end
  end

  defp generate_state(user_id, integration_id) do
    State.generate(user_id, ZoomConfig.state_secret(), integration_id)
  end

  defp verify_state(state) when is_binary(state) do
    State.validate(state, ZoomConfig.state_secret())
  end

  defp verify_state(_arg), do: {:error, "Invalid state parameter"}
end
