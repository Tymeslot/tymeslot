defmodule TymeslotWeb.OAuthFlow do
  @moduledoc """
  The web adapter for social sign-in: starting the flow at the provider,
  handling its callback, and signing an account in on the connection.
  Returns tagged result tuples.

  It lives in the web layer because the flow is carried by the connection:
  the OAuth state and PKCE verifier sit in the Plug session between the
  redirect and the callback (`TymeslotWeb.OAuthFlow.State`), and a sign-in
  ends in a session cookie (`TymeslotWeb.UserAuth`). Every decision (the
  code exchange, which account an identity belongs to, whether it may sign in
  or must verify first, whether a new one may be created) is the domain's,
  reached through `Tymeslot.Auth`.

  All presentation concerns (flash messages, HTTP redirects) are the
  responsibility of the calling controller.
  """

  require Logger

  alias Tymeslot.Auth
  alias Tymeslot.Auth.OAuth.Providers
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.OAuthFlow.State
  alias TymeslotWeb.UserAuth

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
    {conn, Auth.social_authorize_url(provider, callback_url(conn, provider), flow)}
  end

  @doc """
  Handles the complete OAuth callback flow: checks the flow's state and
  recovers its PKCE verifier, lets the domain decide what the callback means
  (`Tymeslot.Auth.resolve_social_callback/5`), and carries the outcome onto
  the connection.

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
  - `{:error, :registration_disabled, provider, conn}` - a new identity, and
    sign-ups are closed.
  """
  @spec handle_oauth_callback(Plug.Conn.t(), oauth_callback_params()) :: flow_result()
  def handle_oauth_callback(conn, %{code: code, state: state, provider: provider}) do
    with {:ok, conn, code_verifier} <- validate_oauth_state(conn, state, provider) do
      provider
      |> Auth.resolve_social_callback(
        code,
        code_verifier,
        callback_url(conn, provider),
        ClientIP.request_opts(conn)
      )
      |> carry(conn, provider)
    end
  end

  @doc """
  Signs in the account a social sign-in resolved to, provided its email is
  verified; the domain decides (`Tymeslot.Auth.admit_social_user/3`).

  An unverified account gets no session: it has been resent its
  verification link, and the conn remembers it for the verify-email screen.
  The last element of `:verification_required` says whether the email went
  out (`:sent`), was refused by the rate limiter (`:rate_limited`) or failed
  (`:failed`).
  """
  @spec sign_in(Plug.Conn.t(), map(), provider()) :: flow_result()
  def sign_in(conn, user, provider) do
    user
    |> Auth.admit_social_user(provider, ClientIP.request_opts(conn))
    |> carry(conn, provider)
  end

  defp carry({:sign_in, user}, conn, provider), do: create_user_session(conn, user, provider)

  defp carry({:verify, user, delivery}, conn, provider),
    do: {:verification_required, UserAuth.put_unverified_user(conn, user), provider, delivery}

  defp carry({:register, pending}, conn, provider),
    do: {:registration_required, conn, provider, pending}

  defp carry({:error, reason}, conn, provider), do: {:error, reason, provider, conn}

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

  # The client this conn came from, on a social-auth audit entry.
  defp log_social_auth(provider, success, conn, details),
    do: Auth.log_social_auth(provider, success, details, ClientIP.request_opts(conn))

  # The endpoint's configured URL when the conn went through one (every real
  # request does), else one built from the conn itself.
  defp callback_url(conn, provider), do: base_url(conn) <> Providers.callback_path(provider)

  defp base_url(%{private: %{phoenix_endpoint: endpoint}}) when endpoint != nil,
    do: endpoint.url()

  defp base_url(conn) do
    case {conn.scheme, conn.port} do
      {:https, 443} -> "https://#{conn.host}"
      {:http, 80} -> "http://#{conn.host}"
      {scheme, port} -> "#{scheme}://#{conn.host}:#{port}"
    end
  end

  defp create_user_session(conn, user, provider) do
    case UserAuth.create_session(conn, %{id: user.id}) do
      {:ok, session_conn, _token} ->
        # Funnel: count OAuth logins alongside password logins. Categorical only
        # (method + provider) - never any user identifier.
        :telemetry.execute([:tymeslot, :auth, :login_completed], %{count: 1}, %{
          method: "oauth",
          provider: to_string(provider)
        })

        # Map.get/2 rather than user.email: an audit line must never be the
        # thing that fails an otherwise successful login.
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
end
