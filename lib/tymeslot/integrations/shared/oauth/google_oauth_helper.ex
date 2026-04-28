defmodule Tymeslot.Integrations.Google.GoogleOAuthHelper do
  @moduledoc """
  Shared Google OAuth helper for all Google integrations.

  This module provides OAuth functionality for Google services including
  Calendar, Google Meet, and other Google APIs. It handles token exchange,
  state management, and provides flexible scope configuration.
  """

  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Common.OAuth.{ErrorParser, IdToken, State, TokenExchange}
  alias Tymeslot.Integrations.Shared.OAuth.TokenFlow

  require Logger

  @default_scopes %{
    openid: "openid",
    email: "email",
    calendar: "https://www.googleapis.com/auth/calendar",
    meet: "https://www.googleapis.com/auth/meetings.space.created"
  }

  @token_url "https://oauth2.googleapis.com/token"

  @doc """
  Generates the OAuth authorization URL for Google services.

  ## Parameters
    - user_id: The user ID for state management
    - redirect_uri: The callback URI after authorization
    - scopes: List of scope atoms or custom scope strings
    - options: Additional OAuth options (access_type, prompt, etc.)

  ## Examples
      authorization_url(123, "https://example.com/callback", [:calendar])
      authorization_url(123, "https://example.com/callback", [:calendar, :meet])
      authorization_url(123, "https://example.com/callback", ["custom.scope"])
  """
  @spec authorization_url(integer(), String.t(), list(atom() | String.t()), keyword()) ::
          String.t()
  def authorization_url(user_id, redirect_uri, scopes, options \\ []) do
    integration_id = Keyword.get(options, :integration_id)
    login_hint = Keyword.get(options, :login_hint)
    return_to = Keyword.get(options, :return_to)
    state = generate_state(user_id, integration_id, return_to: return_to)

    # Always include openid and email for account identification
    all_scopes = Enum.uniq([:openid, :email | scopes])
    scope_string = build_scope_string(all_scopes)

    # Re-auth uses select_account only; new connections use consent + select_account
    default_prompt = if integration_id, do: "select_account", else: "consent select_account"

    base_params = %{
      client_id: google_client_id(),
      redirect_uri: redirect_uri,
      response_type: "code",
      scope: scope_string,
      state: state,
      access_type: Keyword.get(options, :access_type, "offline"),
      prompt: Keyword.get(options, :prompt, default_prompt)
    }

    # Add login_hint if provided
    base_params =
      if login_hint, do: Map.put(base_params, :login_hint, login_hint), else: base_params

    # Add any additional options
    params =
      options
      |> Keyword.drop([:access_type, :prompt, :integration_id, :login_hint])
      |> Enum.into(base_params)

    query_string = URI.encode_query(params)
    "https://accounts.google.com/o/oauth2/v2/auth?" <> query_string
  end

  @doc """
  Exchanges authorization code for access and refresh tokens.

  ## Parameters
    - code: Authorization code from Google
    - redirect_uri: The same redirect URI used in authorization
    - state: State parameter for validation

  Returns {:ok, tokens} or {:error, reason}
  """
  @spec exchange_code_for_tokens(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def exchange_code_for_tokens(code, redirect_uri, state \\ nil) do
    body = %{
      code: code,
      client_id: google_client_id(),
      client_secret: google_client_secret(),
      redirect_uri: redirect_uri,
      grant_type: "authorization_code"
    }

    case TokenFlow.exchange_code(@token_url, body, provider: :google) do
      {:ok, response} ->
        tokens = build_token_map(response)

        case validate_state(state) do
          {:ok, %{user_id: user_id} = state_data} ->
            {:ok,
             tokens
             |> Map.put(:user_id, user_id)
             |> Map.put(:integration_id, state_data.integration_id)}

          {:error, _reason} when is_nil(state) ->
            {:ok, tokens}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, {:http_error, status, body}} ->
        Logger.error("OAuth token exchange failed",
          status: status,
          response_body: Redactor.redact_and_truncate(body)
        )

        {:error, ErrorParser.build_message("OAuth token exchange failed", status, body)}

      {:error, {:network_error, reason}} ->
        Logger.error("Network error during token exchange", reason: inspect(reason))
        {:error, "Network error during token exchange: #{inspect(reason)}"}
    end
  end

  @doc """
  Refreshes an access token using a refresh token.

  ## Parameters
    - refresh_token: The refresh token
    - current_scope: Current token scope (optional)

  Returns {:ok, tokens} or {:error, reason}
  """
  @spec refresh_access_token(String.t(), String.t() | nil) :: {:ok, map()} | {:error, String.t()}
  def refresh_access_token(refresh_token, current_scope \\ nil) do
    body = %{
      refresh_token: refresh_token,
      client_id: google_client_id(),
      client_secret: google_client_secret(),
      grant_type: "refresh_token"
    }

    # Add scope if provided to maintain same scope
    body = if current_scope, do: Map.put(body, :scope, current_scope), else: body

    case TokenExchange.refresh_access_token(@token_url, body,
           fallback_refresh_token: refresh_token,
           fallback_scope: current_scope
         ) do
      {:ok, tokens} ->
        {:ok, tokens}

      {:error, {:http_error, status, body}} ->
        Logger.error("Token refresh failed",
          status: status,
          response_body: Redactor.redact_and_truncate(body)
        )

        {:error, ErrorParser.build_message("Token refresh failed", status, body)}

      {:error, {:network_error, reason}} ->
        Logger.error("Network error during token refresh", reason: inspect(reason))
        {:error, "Network error during token refresh: #{inspect(reason)}"}
    end
  end

  @doc """
  Validates the scope of an access token.

  ## Parameters
    - access_token: The access token to validate
    - expected_scopes: List of expected scope atoms or strings

  Returns {:ok, actual_scopes} or {:error, reason}
  """
  @spec validate_token_scope(String.t(), list(atom() | String.t())) ::
          {:ok, list(String.t())} | {:error, String.t()}
  def validate_token_scope(access_token, expected_scopes \\ []) do
    url = "https://www.googleapis.com/oauth2/v1/tokeninfo"
    headers = [{"Authorization", "Bearer #{access_token}"}]

    case http_client().request(:get, url, "", headers, []) do
      {:ok, %{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, response} ->
            actual_scope = response["scope"] || ""
            actual_scopes = String.split(actual_scope, " ")

            expected_scope_strings = build_scope_list(expected_scopes)

            missing_scopes = expected_scope_strings -- actual_scopes

            if Enum.empty?(missing_scopes) do
              {:ok, actual_scopes}
            else
              {:error, "Token missing required scopes: #{Enum.join(missing_scopes, ", ")}"}
            end

          {:error, _decode_error} ->
            {:error, "Invalid JSON response from token validation endpoint"}
        end

      {:ok, %{status: 400, body: _value}} ->
        {:error, "Invalid or expired access token"}

      {:ok, %{status: status, body: body}} ->
        {:error,
         "Token validation failed: HTTP #{status} - #{Redactor.redact_and_truncate(body)}"}

      {:error, reason} ->
        {:error, "Network error during token validation: #{inspect(reason)}"}
    end
  end

  @doc """
  Generates a secure state parameter for OAuth flow.
  """
  @spec generate_state(integer(), pos_integer() | nil, keyword()) :: String.t()
  def generate_state(user_id, integration_id \\ nil, opts \\ []) do
    State.generate(user_id, state_secret(), integration_id, opts)
  end

  @doc """
  Validates and extracts state data from state parameter.
  """
  @spec validate_state(String.t() | any()) ::
          {:ok, State.validated()} | {:error, String.t()}
  def validate_state(state) when is_binary(state) do
    State.validate(state, state_secret())
  end

  def validate_state(_invalid), do: {:error, "Invalid state parameter"}

  @doc """
  Returns available scope definitions.
  """
  @spec available_scopes() :: map()
  def available_scopes, do: @default_scopes

  @doc """
  Returns the scope string for a given scope atom.
  """
  @spec scope_string(atom()) :: String.t()
  @spec scope_string(String.t()) :: String.t()
  def scope_string(scope_atom) when is_atom(scope_atom) do
    Map.get(@default_scopes, scope_atom, scope_atom)
  end

  def scope_string(scope_string) when is_binary(scope_string), do: scope_string

  # Private functions

  defp build_token_map(response) do
    expires_at = DateTime.add(DateTime.utc_now(), response["expires_in"], :second)

    {provider_account_id, provider_account_email} =
      case IdToken.decode(response["id_token"]) do
        {:ok, claims} ->
          {claims.sub, claims.email}

        {:error, reason} ->
          if response["id_token"] do
            Logger.warning(
              "Failed to decode Google id_token — account dedup falling back to legacy match",
              reason: inspect(reason)
            )
          end

          {nil, nil}
      end

    %{
      access_token: response["access_token"],
      refresh_token: response["refresh_token"],
      expires_at: expires_at,
      scope: response["scope"],
      provider_account_id: provider_account_id,
      provider_account_email: provider_account_email
    }
  end

  defp build_scope_string(scopes) when is_list(scopes) do
    scopes
    |> build_scope_list()
    |> Enum.join(" ")
  end

  defp build_scope_list(scopes) when is_list(scopes) do
    Enum.map(scopes, fn
      scope when is_atom(scope) -> Map.get(@default_scopes, scope, to_string(scope))
      scope when is_binary(scope) -> scope
    end)
  end

  defp google_client_id do
    Application.get_env(:tymeslot, :google_oauth)[:client_id] ||
      System.get_env("GOOGLE_CLIENT_ID") ||
      raise "Google Client ID not configured"
  end

  defp google_client_secret do
    Application.get_env(:tymeslot, :google_oauth)[:client_secret] ||
      System.get_env("GOOGLE_CLIENT_SECRET") ||
      raise "Google Client Secret not configured"
  end

  defp state_secret do
    Application.get_env(:tymeslot, :google_oauth)[:state_secret] ||
      System.get_env("GOOGLE_STATE_SECRET") ||
      raise "Google State Secret not configured"
  end

  defp http_client do
    Application.get_env(:tymeslot, :http_client_module, HTTPClient)
  end
end
