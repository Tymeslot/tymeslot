defmodule Tymeslot.Integrations.Shared.OAuth.GoogleOAuthHelper do
  @moduledoc """
  Shared Google OAuth helper for all Google integrations.

  This module provides OAuth functionality for Google services including
  Calendar, Google Meet, and other Google APIs. It handles token exchange,
  state management, and provides flexible scope configuration.
  """

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Shared.GoogleConfig
  alias Tymeslot.Integrations.Shared.OAuth.IdToken
  alias Tymeslot.Integrations.Shared.OAuth.PendingFlow
  alias Tymeslot.Integrations.Shared.OAuth.ProviderHelpers
  alias Tymeslot.Integrations.Shared.OAuth.State
  alias Tymeslot.Integrations.Shared.OAuth.TokenEndpoint

  require Logger

  # Authorisation parameters a caller may set beyond the ones built here.
  @forwarded_options [:include_granted_scopes, :hd]

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

    state =
      generate_state(user_id, integration_id,
        return_to: return_to,
        nonce: PendingFlow.nonce(options)
      )

    # Always include openid and email for account identification
    all_scopes = Enum.uniq([:openid, :email | scopes])
    scope_string = build_scope_string(all_scopes)

    # Re-auth uses select_account only; new connections use consent + select_account
    default_prompt = if integration_id, do: "select_account", else: "consent select_account"

    base_params = %{
      client_id: GoogleConfig.client_id!(),
      redirect_uri: redirect_uri,
      response_type: "code",
      scope: scope_string,
      state: state,
      access_type: Keyword.get(options, :access_type, "offline"),
      prompt: Keyword.get(options, :prompt, default_prompt)
    }

    # Only parameters Google defines are forwarded: the options also carry
    # Tymeslot's own (`return_to`, `scopes`), which belong in the state or the
    # scope string, not in a URL Google logs and may reject.
    params =
      options
      |> Keyword.take(@forwarded_options)
      |> Enum.into(base_params)
      |> Map.merge(PendingFlow.challenge_params(options))

    ProviderHelpers.build_authorization_url(
      GoogleConfig.authorize_url(),
      params,
      login_hint
    )
  end

  @doc """
  Exchanges an authorisation code for tokens, with the Google account the id
  token names (`provider_account_id`, `provider_account_email`).

  The callback's `state` is verified by the caller before the code is spent;
  `opts` carries its flow's `:code_verifier`.

  Returns {:ok, tokens} or {:error, reason}
  """
  @spec exchange_code_for_tokens(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def exchange_code_for_tokens(code, redirect_uri, opts \\ []) do
    with {:ok, client_id} <- GoogleConfig.fetch_client_id(),
         {:ok, client_secret} <- GoogleConfig.fetch_client_secret() do
      body =
        PendingFlow.verifier_param(opts, %{
          code: code,
          client_id: client_id,
          client_secret: client_secret,
          redirect_uri: redirect_uri,
          grant_type: "authorization_code"
        })

      # No second log line on failure: `TokenEndpoint` already logs the status
      # and the redacted body, and names the provider too.
      case TokenEndpoint.exchange_code(GoogleConfig.token_url(), body,
             log_context: [provider: :google]
           ) do
        {:ok, tokens} -> {:ok, build_token_map(tokens)}
        {:error, error} -> {:error, TokenEndpoint.error_message(:exchange, error)}
      end
    end
  end

  @doc """
  Refreshes an access token using a refresh token.

  This is the Google Meet **video** refresh as well as the calendar one, and
  both log `provider: :google`, so a caller that can name the integration
  should: pass `log_context: [integration_id: id, user_id: user_id]` and the
  two stop being indistinguishable on the line.

  ## Parameters
    - refresh_token: The refresh token
    - current_scope: Current token scope (optional)
    - opts: `:log_context`, forwarded to `TokenEndpoint.refresh/3`

  Returns {:ok, tokens} or {:error, reason}
  """
  @spec refresh_access_token(String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def refresh_access_token(refresh_token, current_scope \\ nil, opts \\ []) do
    # No second log line here: `TokenEndpoint` already logs the status and the
    # redacted body, and names the provider too.
    case TokenEndpoint.refresh_grant(GoogleConfig, refresh_token, current_scope,
           log_context: Keyword.merge(Keyword.get(opts, :log_context, []), provider: :google)
         ) do
      {:ok, tokens} -> {:ok, tokens}
      {:error, error} -> {:error, TokenEndpoint.error_message(:refresh, error)}
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
  Returns the secret used to sign and verify Google OAuth `state` parameters.
  """
  @spec state_secret() :: String.t()
  defdelegate state_secret, to: GoogleConfig

  # Private functions

  # Adds the account the id_token names, so a reconnect can match the
  # integration it belongs to. The token endpoint result itself carries the
  # raw id_token, which nothing downstream needs.
  defp build_token_map(tokens) do
    {provider_account_id, provider_account_email} =
      case IdToken.decode(tokens.id_token) do
        {:ok, claims} ->
          {claims.sub, claims.email}

        {:error, reason} ->
          if tokens.id_token do
            Logger.warning(
              "Failed to decode Google id_token — account dedup falling back to legacy match",
              reason: LogFormat.reason(reason)
            )
          end

          {nil, nil}
      end

    tokens
    |> Map.delete(:id_token)
    |> Map.merge(%{
      provider_account_id: provider_account_id,
      provider_account_email: provider_account_email
    })
  end

  defp build_scope_string(scopes) when is_list(scopes) do
    scopes
    |> build_scope_list()
    |> Enum.join(" ")
  end

  defp build_scope_list(scopes) when is_list(scopes) do
    Enum.map(scopes, fn
      scope when is_atom(scope) -> GoogleConfig.scope(scope)
      scope when is_binary(scope) -> scope
    end)
  end
end
