defmodule Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelper do
  @moduledoc """
  Helper module for Zoom OAuth flow for video integrations.

  Provides functions to generate OAuth URLs and handle the OAuth callback for
  the Zoom REST API v2, used to create scheduled meetings on a connected user's
  Zoom account.

  ## Token endpoint authentication

  Zoom requires HTTP Basic Auth on the token endpoint
  (`Authorization: Basic base64(client_id:client_secret)`). The shared
  `Tymeslot.Integrations.Shared.OAuth.TokenEndpoint` module accepts a `:headers`
  option that lets us thread that header through both the
  authorization-code exchange and the refresh-token flow without duplicating
  HTTP, JSON, retry, redaction, and logging plumbing here.
  """

  @behaviour Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelperBehaviour

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Infrastructure.Retry
  alias Tymeslot.Integrations.Shared.OAuth.PendingFlow
  alias Tymeslot.Integrations.Shared.OAuth.ProviderHelpers
  alias Tymeslot.Integrations.Shared.OAuth.Refresh
  alias Tymeslot.Integrations.Shared.OAuth.State
  alias Tymeslot.Integrations.Shared.OAuth.TokenEndpoint
  alias Tymeslot.Integrations.Shared.ZoomConfig
  alias Tymeslot.Integrations.Video.Providers.ZoomProvider.Scopes

  require Logger

  # The profile is fetched during the OAuth callback, with the owner waiting
  # on the page: a rate limit asking for longer than this fails the connect
  # with its error rather than holding the request.
  @profile_retry [max_rate_limit_wait: 2_000]

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
  @revoke_url "https://zoom.us/oauth/revoke"
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
    state = generate_state(user_id, integration_id, PendingFlow.nonce(options))

    params = %{
      client_id: ZoomConfig.client_id!(),
      redirect_uri: redirect_uri,
      response_type: "code",
      scope: zoom_scope(),
      state: state
    }

    params = Map.merge(params, PendingFlow.challenge_params(options))
    url = ProviderHelpers.build_authorization_url(@authorize_url, params, login_hint)
    Logger.info("Generated Zoom OAuth URL", scope: zoom_scope())
    url
  end

  @doc """
  Exchanges authorization code for access and refresh tokens.

  Exchanges the code (the caller has verified the state), then fetches the
  Zoom user profile so the integration can be uniquely identified by the Zoom account ID.

  `profile_retry:` takes `Tymeslot.Infrastructure.Retry` options for the
  profile request (tests shorten its delays).
  """
  @impl Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelperBehaviour
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

  @doc """
  Refreshes an access token using the refresh token.

  `opts` takes a `:log_context`, forwarded to
  `TokenEndpoint.refresh/3`. Callers holding the integration ids
  should pass them: without them a failure line names only the provider.
  """
  @impl Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelperBehaviour
  @spec refresh_access_token(String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def refresh_access_token(refresh_token, current_scope \\ nil, opts \\ []) do
    scope = current_scope || zoom_scope()

    body = %{
      grant_type: "refresh_token",
      refresh_token: refresh_token
    }

    with {:ok, headers} <- basic_auth_headers() do
      # No second log line here: `TokenEndpoint` already logs the status and
      # the redacted body, and names the provider too.
      case TokenEndpoint.refresh(@token_url, body,
             fallback_refresh_token: refresh_token,
             fallback_scope: scope,
             headers: headers,
             log_context: Keyword.merge(Keyword.get(opts, :log_context, []), provider: :zoom)
           ) do
        {:ok, tokens} -> {:ok, tokens}
        {:error, error} -> {:error, TokenEndpoint.error_message(:refresh, error)}
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
    # The expiry buffer is shared with every OAuth integration
    # (`Tymeslot.Integrations.Shared.OAuth.Refresh.valid?/2`). An unknown
    # expiry means refresh: a token whose lifetime was never stored is
    # renewed rather than trusted or refused.
    if Refresh.valid?(Map.get(config, :token_expires_at)),
      do: {:ok, :valid},
      else: {:ok, :needs_refresh}
  end

  # Private helpers

  defp build_result_tokens(tokens, profile) do
    Map.merge(tokens, %{
      provider_account_id: profile["id"],
      provider_account_email: profile["email"],
      scope: tokens[:scope] || zoom_scope()
    })
  end

  # Zoom takes the client credentials as basic auth, not in the body.
  defp fetch_tokens(code, redirect_uri, opts) do
    body =
      PendingFlow.verifier_param(opts, %{
        code: code,
        redirect_uri: redirect_uri,
        grant_type: "authorization_code",
        scope: zoom_scope()
      })

    with {:ok, headers} <- basic_auth_headers() do
      case TokenEndpoint.exchange_code(@token_url, body,
             fallback_scope: zoom_scope(),
             headers: headers,
             log_context: [provider: :zoom]
           ) do
        {:ok, tokens} -> {:ok, tokens}
        {:error, error} -> {:error, TokenEndpoint.error_message(:exchange, error)}
      end
    end
  end

  defp fetch_user_profile(token, opts) do
    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"}
    ]

    # The reason stays structured inside the retry, so a 5xx or a dropped
    # connection is retried and the message names what failed last.
    fn ->
      case Config.http_client_module().get(@user_profile_url, headers, []) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          parse_profile_body(body)

        # Retried after the wait the provider names, when it names one.
        {:ok, %Req.Response{status: 429} = response} ->
          Logger.warning("Zoom user profile request rate limited")
          {:error, {:rate_limited, Retry.retry_after_seconds(response)}}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.error("Failed to fetch Zoom user profile",
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

  @doc """
  Revokes the Zoom app authorisation behind `access_token` (Zoom revokes by
  access token, authenticated with the app's client credentials). Not a
  behaviour callback: only account deletion calls it, directly.
  """
  @spec revoke_token(String.t()) :: :ok | {:error, term()}
  def revoke_token(access_token) when is_binary(access_token) do
    url = @revoke_url <> "?" <> URI.encode_query(%{"token" => access_token})

    with {:ok, headers} <- basic_auth_headers() do
      case Config.http_client_module().post(url, "", headers, receive_timeout: 10_000) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: 400, body: body}} -> revoke_bad_request(body)
        {:ok, %{status: status}} -> {:error, {:http_error, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # A token Zoom no longer knows (already revoked, or the user removed the
  # app) leaves nothing to revoke, so it counts as done, as it does for
  # Google. Any other 400, such as bad client credentials, is a failure.
  defp revoke_bad_request(body) do
    if unknown_token?(body), do: :ok, else: {:error, {:http_error, 400}}
  end

  defp unknown_token?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> unknown_token?(decoded)
      {:error, _reason} -> false
    end
  end

  defp unknown_token?(%{"reason" => reason}) when is_binary(reason),
    do:
      reason
      |> String.downcase()
      |> String.contains?(["invalid token", "invalid access token", "token not found"])

  defp unknown_token?(_body), do: false

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

  defp generate_state(user_id, integration_id, nonce) do
    State.generate(user_id, ZoomConfig.state_secret(), integration_id, nonce: nonce)
  end
end
