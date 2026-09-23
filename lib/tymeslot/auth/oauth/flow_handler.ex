defmodule Tymeslot.Auth.OAuth.FlowHandler do
  @moduledoc """
  Orchestrates social sign-in: starting the flow at the provider, handling
  its callback, and signing an account in. Returns tagged result tuples.

  All presentation concerns (flash messages, HTTP redirects) are the
  responsibility of the calling controller.
  """

  require Logger

  alias Tymeslot.Auth.OAuth.{Client, Providers, State, URLs, UserProcessor, UserRegistration}

  alias Tymeslot.Auth.{Session, Verification}
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Security.SecurityLogger
  alias TymeslotWeb.Helpers.ClientIP

  @type provider :: Providers.provider()

  @type oauth_callback_params :: %{code: String.t(), state: String.t(), provider: provider()}

  @type flow_result ::
          {:ok, Plug.Conn.t(), provider()}
          | {:verification_required, Plug.Conn.t(), provider(), :sent | :rate_limited | :failed}
          | {:registration_required, Plug.Conn.t(), provider(), map()}
          | {:error, :invalid_state, Plug.Conn.t()}
          | {:error, :oauth_error | :general_error | :session_failed, provider(), Plug.Conn.t()}
          | {:error, :registration_disabled | :email_already_taken, provider(), Plug.Conn.t()}

  @doc """
  Starts a sign-in: issues the state and PKCE verifier into the session and
  returns the provider's authorise URL.
  """
  @spec authorize(Plug.Conn.t(), provider()) :: {Plug.Conn.t(), String.t()}
  def authorize(conn, provider) do
    {conn, flow} = State.generate_and_store_state(conn)
    {conn, Client.authorize_url(provider, callback_url(conn, provider), flow)}
  end

  @doc """
  Handles the complete OAuth callback flow.

  Returns a tagged tuple describing the outcome. Callers are responsible for
  translating each variant into flash messages and HTTP redirects:

  - `{:ok, conn, provider}` - session established; redirect to success path.
  - `{:verification_required, conn, provider, delivery}` - the account's
    email is unverified; no session, see `sign_in/3`.
  - `{:registration_required, conn, provider, params}` - new user; redirect to
    the registration form, passing `params` as query string.
  - `{:error, :invalid_state, conn}` - CSRF state mismatch.
  - `{:error, :oauth_error, provider, conn}` - the provider refused the code
    exchange or a request made with its token.
  - `{:error, :general_error, provider, conn}` - the provider could not be
    reached, or its response was unusable.
  - `{:error, :session_failed, provider, conn}` - OAuth succeeded but session
    creation failed.
  - `{:error, :email_already_taken, provider, conn}` - no account carries this
    provider ID, but the email belongs to an account created another way.
  """
  @spec handle_oauth_callback(Plug.Conn.t(), oauth_callback_params()) :: flow_result()
  def handle_oauth_callback(conn, %{code: code, state: state, provider: provider}) do
    with {:ok, conn, code_verifier} <- validate_oauth_state(conn, state, provider),
         {:ok, conn, user} <- process_oauth_response(conn, code, code_verifier, provider) do
      complete_oauth_flow(conn, user, provider)
    end
  end

  # Private helpers

  # The provider is threaded in purely so the audit entry can name it: a
  # social auth failure that cannot distinguish Google from GitHub is not much
  # of an audit trail.
  defp validate_oauth_state(conn, state, provider) do
    case State.validate_state(conn, state) do
      {:ok, code_verifier} ->
        {:ok, State.clear_oauth_state(conn), code_verifier}

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

  defp process_oauth_response(conn, code, code_verifier, provider) do
    with {:ok, token} <-
           Client.exchange_code(provider, code, code_verifier, callback_url(conn, provider)),
         {:ok, identity} <- UserProcessor.fetch_identity(provider, token) do
      {:ok, conn, identity}
    else
      {:error, reason} ->
        error =
          if match?({:provider_rejected, _status}, reason), do: :oauth_error, else: :general_error

        Logger.error("OAuth authentication error",
          provider: to_string(provider),
          reason: inspect(reason)
        )

        log_social_auth(provider, false, conn, %{error_reason: Atom.to_string(error)})
        {:error, error, provider, conn}
    end
  end

  defp callback_url(conn, provider),
    do: URLs.callback_url(conn, Providers.callback_path(provider))

  # An account created before the provider's word counted (or with a typed
  # address the provider has since verified) is verified on the spot when the
  # provider vouches for the very address on record, rather than being sent
  # an email proving what the provider already has.
  defp verify_vouched_email(%{verified_at: nil, email: email} = account, %{
         email_from_provider: true,
         email: vouched
       })
       when is_binary(email) and is_binary(vouched) do
    with true <- String.downcase(email) == String.downcase(vouched),
         {:ok, verified} <- Verification.verify_user(account.id) do
      verified
    else
      _not_vouched_or_failed -> account
    end
  end

  defp verify_vouched_email(account, _identity), do: account

  defp complete_oauth_flow(conn, user, provider) do
    case UserRegistration.find_existing_user(provider, user) do
      {:ok, existing_user} ->
        sign_in(conn, verify_vouched_email(existing_user, user), provider)

      {:error, :not_found} ->
        handle_new_user_registration(conn, provider, user)

      {:error, :email_already_taken} ->
        log_social_auth(provider, false, conn, %{
          email: Map.get(user, :email),
          error_reason: "email_already_taken"
        })

        {:error, :email_already_taken, provider, conn}
    end
  end

  @doc """
  Signs in the account an OAuth identity belongs to, provided its email is
  verified.

  An unverified account gets no session: its email is resent the
  verification link (rate limited) and the conn remembers the account for the
  verify-email screen. The last element of `:verification_required` says
  whether the email went out (`:sent`), was refused by the rate limiter
  (`:rate_limited`) or failed (`:failed`).
  """
  @spec sign_in(Plug.Conn.t(), map(), provider()) :: flow_result()
  def sign_in(conn, %{verified_at: nil} = user, provider) do
    delivery =
      case Verification.resend_verification_email(conn, user) do
        {:ok, _user} -> :sent
        {:error, :rate_limited, _message} -> :rate_limited
        {:error, _reason} -> :failed
      end

    log_social_auth(provider, false, conn, %{
      email: Map.get(user, :email),
      error_reason: "email_not_verified"
    })

    {:verification_required, Session.put_unverified_user(conn, user), provider, delivery}
  end

  def sign_in(conn, user, provider), do: create_user_session(conn, user, provider)

  defp create_user_session(conn, user, provider) do
    case Session.create_session(conn, %{id: user.id}) do
      {:ok, session_conn, _token} ->
        # Funnel: count OAuth logins alongside password logins. Categorical only
        # (method + provider) - never any user identifier.
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

  # A new identity always goes through the complete-registration form, even
  # with every field known: the account is created on explicit confirmation,
  # never silently.
  defp handle_new_user_registration(conn, provider, user) do
    if Config.registration_enabled?() do
      {:registration_required, conn, provider, build_registration_data(provider, user)}
    else
      log_social_auth(provider, false, conn, %{
        email: Map.get(user, :email),
        error_reason: "registration_disabled"
      })

      {:error, :registration_disabled, provider, conn}
    end
  end

  # Kept in the session until the complete-registration form is submitted.
  # `created_at` (unix seconds) lets the completion refuse a stale entry.
  defp build_registration_data(provider, user) do
    %{
      provider: to_string(provider),
      email: user.email || "",
      name: user.name || "",
      email_from_provider: user.email_from_provider == true,
      provider_uid: user.provider_uid,
      created_at: DateTime.to_unix(Clock.utc_now())
    }
  end
end
