defmodule Tymeslot.Integrations.Video.Teams.TeamsOAuthHelper do
  @moduledoc """
  Helper module for Microsoft Teams OAuth flow for video integrations.

  This module provides functions to generate OAuth URLs and handle
  the OAuth callback   for Microsoft Graph API integration specifically
  for Teams meeting creation.
  """

  @behaviour Tymeslot.Integrations.Video.Teams.TeamsOAuthHelperBehaviour

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Infrastructure.Retry
  alias Tymeslot.Integrations.Shared.MicrosoftConfig
  alias Tymeslot.Integrations.Shared.OAuth.IdToken
  alias Tymeslot.Integrations.Shared.OAuth.PendingFlow
  alias Tymeslot.Integrations.Shared.OAuth.ProviderHelpers
  alias Tymeslot.Integrations.Shared.OAuth.Refresh
  alias Tymeslot.Integrations.Shared.OAuth.State
  alias Tymeslot.Integrations.Shared.OAuth.TokenEndpoint

  require Logger

  # The profile is fetched during the OAuth callback, with the owner waiting
  # on the page: a rate limit asking for longer than this fails the connect
  # with its error rather than holding the request.
  @profile_retry [max_rate_limit_wait: 2_000]

  @doc """
  Generates the OAuth authorization URL for Microsoft Teams.
  """
  @spec authorization_url(term(), String.t(), keyword()) :: String.t()
  def authorization_url(user_id, redirect_uri, options \\ []) do
    integration_id = Keyword.get(options, :integration_id)
    login_hint = Keyword.get(options, :login_hint)
    state = generate_state(user_id, integration_id, PendingFlow.nonce(options))

    params = %{
      client_id: MicrosoftConfig.client_id!(),
      redirect_uri: redirect_uri,
      response_type: "code",
      scope: MicrosoftConfig.scope(),
      state: state,
      response_mode: "query",
      prompt: "select_account"
    }

    params = Map.merge(params, PendingFlow.challenge_params(options))

    url =
      ProviderHelpers.build_authorization_url(MicrosoftConfig.authorize_url(), params, login_hint)

    Logger.info("Generated Teams OAuth URL", scope: MicrosoftConfig.scope())
    url
  end

  @doc """
  Exchanges authorization code for access and refresh tokens.
  Also fetches the user profile to get the Microsoft user ID and tenant ID.

  `profile_retry:` takes `Tymeslot.Infrastructure.Retry` options for the
  profile request (tests shorten its delays).
  """
  @spec exchange_code_for_tokens(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t() | :provider_rate_limited}
  # credo:disable-for-next-line Credo.Check.Design.DuplicatedCode
  def exchange_code_for_tokens(code, redirect_uri, opts \\ []) do
    with {:ok, tokens} <- fetch_tokens(code, redirect_uri, opts),
         :ok <- verify_required_scopes(tokens),
         {:ok, profile} <- fetch_user_profile(tokens.access_token, opts) do
      {:ok, build_result_tokens(tokens, profile)}
    end
  end

  defp build_result_tokens(tokens, profile) do
    id_claims = decode_id_claims(tokens)

    Map.merge(tokens, %{
      teams_user_id: profile["id"],
      tenant_id: id_claims.tid || profile["tenant_id"] || "common",
      provider_account_id: id_claims.oid || profile["id"],
      provider_account_email: id_claims.email || profile["mail"],
      scope: ensure_calendar_scope(tokens)
    })
  end

  defp decode_id_claims(tokens) do
    case IdToken.decode(tokens[:id_token]) do
      {:ok, claims} ->
        claims

      {:error, reason} ->
        if tokens[:id_token] do
          Logger.warning(
            "Failed to decode Teams id_token — account dedup falling back to profile data",
            reason: LogFormat.reason(reason)
          )
        end

        %{oid: nil, email: nil, tid: nil}
    end
  end

  defp ensure_calendar_scope(tokens) do
    returned_scope = tokens[:scope] || ""

    if String.contains?(returned_scope, "Calendars.ReadWrite"),
      do: returned_scope,
      else: MicrosoftConfig.scope()
  end

  defp fetch_user_profile(token, opts) do
    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"}
    ]

    # The reason stays structured inside the retry, so a 5xx or a dropped
    # connection is retried and the message names what failed last.
    fn ->
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

        # Retried after the wait the provider names, when it names one.
        {:ok, %Req.Response{status: 429} = response} ->
          Logger.warning("Microsoft user profile request rate limited")
          {:error, {:rate_limited, Retry.retry_after_seconds(response)}}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.error("Failed to fetch Microsoft user profile",
            status: status,
            body: Redactor.redact_and_truncate(body)
          )

          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
    |> Retry.with_backoff(Keyword.merge(@profile_retry, Keyword.get(opts, :profile_retry, [])))
    |> profile_error_message()
  end

  defp profile_error_message({:error, {:http_error, status, _body}}),
    do: {:error, "Failed to fetch user profile: HTTP #{status}"}

  # The owner is told the provider is busy, rather than shown a status code.
  defp profile_error_message({:error, {:rate_limited, _seconds}}),
    do: {:error, :provider_rate_limited}

  defp profile_error_message({:error, exception}) when is_exception(exception),
    do: {:error, "Network error fetching profile: #{Exception.message(exception)}"}

  defp profile_error_message({:error, reason}) when is_binary(reason), do: {:error, reason}

  defp profile_error_message({:error, reason}),
    do: {:error, "Network error fetching profile: #{inspect(reason)}"}

  defp profile_error_message(result), do: result

  @doc """
  Refreshes an access token using the refresh token.

  `opts` takes a `:log_context`, forwarded to
  `TokenEndpoint.refresh/3`. Callers holding the integration ids
  should pass them: without them a failure line names only the provider.
  """
  @spec refresh_access_token(String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def refresh_access_token(refresh_token, current_scope \\ nil, opts \\ []) do
    # No second log line here: `TokenEndpoint` already logs the status and the
    # redacted body, and names the provider too.
    case TokenEndpoint.refresh_grant(
           MicrosoftConfig,
           refresh_token,
           current_scope || MicrosoftConfig.scope(),
           log_context: Keyword.merge(Keyword.get(opts, :log_context, []), provider: :teams)
         ) do
      {:ok, tokens} -> {:ok, tokens}
      {:error, error} -> {:error, TokenEndpoint.error_message(:refresh, error)}
    end
  end

  @doc """
  Validates if a token is still valid or needs refresh.
  """
  @spec validate_token(%{optional(:token_expires_at) => DateTime.t()}) ::
          {:ok, :valid | :needs_refresh} | {:error, String.t()}
  def validate_token(config) do
    # The expiry buffer is shared with every OAuth integration
    # (`Tymeslot.Integrations.Shared.OAuth.Refresh.valid?/2`). An unknown
    # expiry means refresh: a token whose lifetime was never stored is
    # renewed rather than trusted or refused.
    if Refresh.valid?(Map.get(config, :token_expires_at)),
      do: {:ok, :valid},
      else: {:ok, :needs_refresh}
  end

  # Private functions

  defp fetch_tokens(code, redirect_uri, opts) do
    with {:ok, client_id} <- MicrosoftConfig.fetch_client_id(),
         {:ok, client_secret} <- MicrosoftConfig.fetch_client_secret() do
      body =
        PendingFlow.verifier_param(opts, %{
          code: code,
          client_id: client_id,
          client_secret: client_secret,
          redirect_uri: redirect_uri,
          grant_type: "authorization_code",
          scope: MicrosoftConfig.scope()
        })

      case TokenEndpoint.exchange_code(MicrosoftConfig.token_url(), body,
             fallback_scope: MicrosoftConfig.scope(),
             log_context: [provider: :teams]
           ) do
        {:ok, tokens} -> {:ok, tokens}
        {:error, error} -> {:error, TokenEndpoint.error_message(:exchange, error)}
      end
    end
  end

  defp generate_state(user_id, integration_id, nonce) do
    State.generate(user_id, MicrosoftConfig.state_secret(), integration_id, nonce: nonce)
  end

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
