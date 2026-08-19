defmodule Tymeslot.Auth.OAuth.FlowHandler do
  @moduledoc """
  Orchestrates the OAuth callback flow, returning tagged result tuples.

  All presentation concerns (flash messages, HTTP redirects) are the
  responsibility of the calling controller.
  """

  require Logger

  alias Tymeslot.Auth.OAuth.{
    Client,
    HelperBehaviour,
    State,
    URLs,
    UserProcessor,
    UserRegistration
  }

  alias Tymeslot.Auth.Session
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Security.SecurityLogger
  alias TymeslotWeb.Helpers.ClientIP

  @type provider :: :github | :google | :oauth
  @type flow_result :: HelperBehaviour.flow_result()
  @type oauth_callback_params :: HelperBehaviour.oauth_callback_params()

  @doc """
  Handles the complete OAuth callback flow.

  Returns a tagged tuple describing the outcome. Callers are responsible for
  translating each variant into flash messages and HTTP redirects:

  - `{:ok, conn, provider}` — session established; redirect to success path.
  - `{:registration_required, conn, provider, params}` — new user; redirect to
    the registration form, passing `params` as query string.
  - `{:error, :invalid_state, conn}` — CSRF state mismatch.
  - `{:error, :oauth_error, provider, conn}` — OAuth2 protocol error.
  - `{:error, :general_error, provider, conn}` — unexpected error during token
    exchange or user processing.
  - `{:error, :session_failed, provider, conn}` — OAuth succeeded but session
    creation failed.
  """
  @spec handle_oauth_callback(Plug.Conn.t(), oauth_callback_params()) :: flow_result()
  def handle_oauth_callback(conn, %{code: code, state: state, provider: provider}) do
    with {:ok, conn} <- validate_oauth_state(conn, state, provider),
         {:ok, conn, user} <- process_oauth_response(conn, code, provider) do
      complete_oauth_flow(conn, user, provider)
    end
  end

  # Private helpers

  # The provider is threaded in purely so the audit entry can name it: a
  # social auth failure that cannot distinguish Google from GitHub is not much
  # of an audit trail.
  defp validate_oauth_state(conn, state, provider) do
    case State.validate_state(conn, state) do
      :ok ->
        {:ok, State.clear_oauth_state(conn)}

      {:error, :invalid_state} ->
        Logger.warning("OAuth callback received with invalid or missing state parameter")

        log_social_auth(provider, false, conn, %{
          oauth_state_valid: false,
          error_reason: "invalid_state"
        })

        {:error, :invalid_state, conn}
    end
  end

  @doc """
  Records a social-auth audit entry via `SecurityLogger.log_social_auth_event/3`.

  Shared by every OAuth entry point (callback flow here, and the
  complete-registration controller) so the audit shape stays in one place.
  No email is available in the CSRF-state and early-error branches; the
  masking helper drops a nil address cleanly. The OAuth code, state and
  client tokens are never recorded.
  """
  @spec log_social_auth(provider() | String.t(), boolean(), Plug.Conn.t(), map()) :: :ok
  def log_social_auth(provider, success, conn, details) do
    SecurityLogger.log_social_auth_event(
      to_string(provider),
      success,
      Map.merge(
        %{ip_address: ClientIP.get(conn), user_agent: ClientIP.get_user_agent(conn)},
        details
      )
    )
  end

  defp process_oauth_response(conn, code, provider) do
    full_callback_url = URLs.callback_url(conn, URLs.callback_path(provider))
    client = Client.build(provider, full_callback_url, "")

    with {:ok, client} <- Client.exchange_code_for_token(client, code),
         {:ok, user_info} <- Client.get_user_info(client, provider),
         {:ok, user} <- UserProcessor.process_user(provider, user_info) do
      enhanced_user = UserProcessor.enhance_user_data(provider, user, client)
      {:ok, conn, enhanced_user}
    else
      {:error, %OAuth2.Error{} = error} ->
        Logger.error("OAuth error", provider: to_string(provider), error: inspect(error))
        log_social_auth(provider, false, conn, %{error_reason: "oauth_error"})
        {:error, :oauth_error, provider, conn}

      {:error, reason} ->
        Logger.error("OAuth authentication error",
          provider: to_string(provider),
          reason: inspect(reason)
        )

        log_social_auth(provider, false, conn, %{error_reason: "general_error"})
        {:error, :general_error, provider, conn}
    end
  end

  defp complete_oauth_flow(conn, user, provider) do
    case UserRegistration.find_existing_user(provider, user) do
      {:ok, existing_user} ->
        create_user_session(conn, existing_user, provider)

      {:error, :not_found} ->
        handle_new_user_registration(conn, provider, user)
    end
  end

  defp create_user_session(conn, user, provider) do
    case Session.create_session(conn, %{id: user.id}) do
      {:ok, session_conn, _token} ->
        # Funnel: count OAuth logins alongside password logins. Categorical only
        # (method + provider) — never any user identifier.
        :telemetry.execute([:tymeslot, :auth, :login_completed], %{count: 1}, %{
          method: "oauth",
          provider: to_string(provider)
        })

        # Map.get/2 rather than user.email: create_user_session/3 is reached
        # with whatever find_existing_user/2 returned, and an audit line must
        # never be the thing that fails an otherwise successful login.
        log_social_auth(provider, true, session_conn, %{
          email: Map.get(user, :email),
          oauth_state_valid: true
        })

        {:ok, session_conn, provider}

      {:error, reason, _message} ->
        Logger.error("Failed to create session after OAuth auth",
          provider: to_string(provider),
          reason: inspect(reason)
        )

        log_social_auth(provider, false, conn, %{
          email: Map.get(user, :email),
          error_reason: "session_failed"
        })

        {:error, :session_failed, provider, conn}
    end
  end

  defp handle_new_user_registration(conn, provider, user) do
    if Config.registration_enabled?() do
      case UserRegistration.check_oauth_requirements(provider, user) do
        {:missing, _missing_fields} ->
          {:registration_required, conn, provider, build_registration_data(provider, user)}

        :complete ->
          # All required fields are present but no account exists yet. Route the
          # user through the registration form for explicit confirmation rather
          # than silently auto-creating an account.
          Logger.warning(
            "OAuth user data is complete but no account found; routing to registration",
            provider: to_string(provider)
          )

          {:registration_required, conn, provider, build_registration_data(provider, user)}
      end
    else
      log_social_auth(provider, false, conn, %{
        email: Map.get(user, :email),
        error_reason: "registration_disabled"
      })

      {:error, :registration_disabled, provider, conn}
    end
  end

  defp build_registration_data(provider, user) do
    %{
      provider: to_string(provider),
      email: user.email || "",
      name: user.name || "",
      is_verified: user.is_verified == true,
      email_from_provider: Map.get(user, :email_from_provider, false),
      provider_uid: to_string(Map.get(user, :provider_uid) || ""),
      github_user_id: Map.get(user, :github_user_id),
      google_user_id: Map.get(user, :google_user_id)
    }
  end
end
