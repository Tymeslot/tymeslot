defmodule TymeslotWeb.OAuthController do
  @moduledoc """
  Handles OAuth authentication flows for GitHub, Google, and generic
  OAuth/OIDC SSO providers.
  """

  use TymeslotWeb, :controller
  use Gettext, backend: TymeslotWeb.Gettext
  require Logger

  alias Tymeslot.Auth.{AuthActions, RateLimit, SocialAuthentication}
  alias Tymeslot.Auth.OAuth.{Providers, SignupConfirmation}
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.AuthControllerHelpers
  alias TymeslotWeb.EmailLinkConfirmHTML
  alias TymeslotWeb.Helpers.{ClientIP, RedirectSanitizer}
  alias TymeslotWeb.OAuthFlow

  @type provider :: Providers.provider()

  @doc """
  Generic OAuth request handler that dispatches to provider-specific functions.
  Checks if social authentication is enabled for the provider when used for auth.
  """
  @spec request(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def request(conn, %{"provider" => provider}) do
    case validate_oauth_provider(provider) do
      {:ok, provider_atom} ->
        dispatch_request(conn, provider_atom)

      {:error, :unsupported_oauth_provider} ->
        unsupported_provider(conn, provider, ~p"/auth/login")
    end
  end

  def request(conn, _params) do
    conn
    |> put_flash(:error, dgettext("auth", "OAuth authentication failed - missing provider."))
    |> redirect(to: ~p"/auth/login")
  end

  defp dispatch_request(conn, provider) do
    if social_auth_enabled?(provider) do
      with_rate_limit(conn, :initiation, fn -> do_provider_auth(conn, provider) end)
    else
      disabled_redirect(conn, provider)
    end
  end

  defp social_auth_enabled?(provider), do: Providers.enabled?(provider)

  defp do_provider_auth(conn, provider) do
    {updated_conn, authorize_url} = OAuthFlow.authorize(conn, provider)
    redirect(updated_conn, external: authorize_url)
  end

  defp unsupported_provider(conn, provider, redirect_path) do
    conn
    |> put_flash(
      :error,
      dgettext("auth", "Unsupported OAuth provider: %{provider}", provider: provider)
    )
    |> redirect(to: redirect_path)
  end

  # Every public entry point is rate limited by IP; the violation is logged
  # and answered the same way, so a new action cannot apply half the gate.
  defp with_rate_limit(conn, action, on_allowed) do
    [ip: ip, user_agent: user_agent] = ClientIP.request_opts(conn)
    {check, event, message, redirect_path} = rate_limit(action, conn)
    context = [event: event, identifier: ip, ip: ip, user_agent: user_agent]

    case RateLimit.check(check.(ip), context) do
      :ok ->
        on_allowed.()

      {:error, :rate_limited, _message} ->
        AuthControllerHelpers.handle_rate_limited(conn, message, redirect_path)
    end
  end

  defp rate_limit(:initiation, _conn) do
    {&RateLimiter.check_oauth_initiation_rate_limit/1, "oauth_initiation",
     dgettext("auth", "Too many OAuth attempts. Please try again later."), ~p"/auth/login"}
  end

  defp rate_limit(:callback, conn) do
    {&RateLimiter.check_oauth_callback_rate_limit/1, "oauth_callback",
     dgettext("auth", "Too many authentication attempts. Please try again later."),
     get_login_path(conn)}
  end

  defp rate_limit(:completion, _conn) do
    {&RateLimiter.check_oauth_completion_rate_limit/1, "oauth_completion",
     dgettext("auth", "Too many registration attempts. Please try again later."), ~p"/auth/login"}
  end

  defp disabled_redirect(conn, provider_atom) do
    conn
    |> put_flash(
      :error,
      dgettext("auth", "%{provider} authentication is not available",
        provider: provider_name(provider_atom)
      )
    )
    |> redirect(to: ~p"/auth/login")
  end

  @doc """
  Generic OAuth callback handler. Validates the provider, then delegates to the shared
  callback handler or returns a provider-specific error.
  """
  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, %{"provider" => provider, "code" => code, "state" => state}) do
    case validate_oauth_provider(provider) do
      {:ok, provider_atom} ->
        # Checked again here, not only when the flow starts: a flow begun
        # before an admin switched the provider off must not still sign in.
        if social_auth_enabled?(provider_atom) do
          with_rate_limit(conn, :callback, fn ->
            handle_provider_callback(conn, provider_atom, code, state)
          end)
        else
          disabled_redirect(conn, provider_atom)
        end

      {:error, :unsupported_oauth_provider} ->
        unsupported_provider(conn, provider, get_login_path(conn))
    end
  end

  def callback(conn, %{"provider" => provider}) do
    case validate_oauth_provider(provider) do
      {:ok, provider_atom} ->
        conn
        |> put_flash(
          :error,
          dgettext(
            "auth",
            "%{provider} authentication failed - missing authorization code or security token.",
            provider: provider_name(provider_atom)
          )
        )
        |> redirect(to: ~p"/?auth=login")

      {:error, :unsupported_oauth_provider} ->
        unsupported_provider(conn, provider, get_login_path(conn))
    end
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, dgettext("auth", "OAuth authentication failed - missing provider."))
    |> redirect(to: get_login_path(conn))
  end

  @doc """
  Handles OAuth completion form submission from modal.
  """
  @spec complete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def complete(conn, params) do
    with_rate_limit(conn, :completion, fn -> process_oauth_completion(conn, params) end)
  end

  # Private helper functions

  defp handle_provider_callback(conn, provider, code, state) do
    paths = get_redirect_paths(conn)

    conn
    |> OAuthFlow.handle_oauth_callback(%{
      code: code,
      state: state,
      provider: provider
    })
    |> respond_to_oauth_result(paths)
  end

  defp process_oauth_completion(conn, params) do
    pending = get_session(conn, :pending_oauth_registration)

    case SocialAuthentication.complete_registration(pending, params, signup_metadata(conn)) do
      # An address typed into the form, taken or free: nothing was created,
      # and both are answered with the same page, flash and session.
      {:ok, provider, :check_email, delivery} ->
        conn
        |> delete_session(:pending_oauth_registration)
        |> check_your_email(provider, delivery)

      {:ok, provider, user, :created} ->
        conn
        |> delete_session(:pending_oauth_registration)
        |> OAuthFlow.sign_in(user, provider)
        |> respond_to_completion()

      # The account already existed (the form was submitted twice): this is a
      # sign-in, and says so.
      {:ok, provider, user, :existing} ->
        conn
        |> delete_session(:pending_oauth_registration)
        |> OAuthFlow.sign_in(user, provider)
        |> respond_to_oauth_result(success_path: ~p"/dashboard", login_path: ~p"/auth/login")

      {:error, reason} ->
        completion_failed(conn, reason, pending)
    end
  end

  defp check_your_email(conn, provider, delivery) do
    message =
      case delivery do
        :sent ->
          dgettext(
            "auth",
            "Check your email: we've sent a link to finish signing up with %{provider}.",
            provider: provider_name(provider)
          )

        :rate_limited ->
          dgettext(
            "auth",
            "We couldn't send the link to finish signing up just now. Please try again later."
          )
      end

    conn
    |> put_flash(:info, message)
    |> redirect(to: ~p"/auth/verify-email")
  end

  @doc """
  Landing page for the link that finishes a social sign-up with a typed
  address. Renders a confirmation button only: opening the link must not
  create the account, or a mail scanner prefetching it would.
  """
  @spec confirm_signup(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm_signup(conn, %{"token" => token}) do
    conn
    |> put_layout(html: false)
    |> put_view(html: EmailLinkConfirmHTML)
    |> render(:confirm,
      action: ~p"/auth/oauth/confirm/#{token}",
      icon: "hero-envelope",
      title: dgettext("auth", "Finish signing up"),
      body:
        dgettext(
          "auth",
          "Press the button below to confirm your email address and create your account."
        ),
      button: dgettext("auth", "Create my account")
    )
  end

  @doc """
  Finishes a social sign-up from its emailed link: creates the account,
  verified, and signs the owner in.
  """
  @spec finish_signup(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def finish_signup(conn, %{"token" => token}) do
    with_rate_limit(conn, :completion, fn ->
      case SignupConfirmation.confirm(token, signup_metadata(conn)) do
        {:ok, provider, user} ->
          conn
          |> OAuthFlow.sign_in(user, provider)
          |> respond_to_completion()

        {:error, :invalid_link} ->
          conn
          |> put_flash(
            :error,
            dgettext("auth", "This link is no longer valid. Please sign in to continue.")
          )
          |> redirect(to: ~p"/auth/login")
      end
    end)
  end

  # Forwarded with the registration broadcast a completed sign-up publishes.
  defp signup_metadata(conn) do
    conn |> ClientIP.request_opts() |> Map.new() |> Map.put(:source, "oauth_signup")
  end

  defp respond_to_completion({:ok, authed_conn, provider}) do
    authed_conn
    |> put_flash(:info, get_welcome_message(provider))
    |> redirect(to: ~p"/dashboard")
  end

  defp respond_to_completion({:error, :session_failed, _provider, conn}) do
    conn
    |> put_flash(:error, dgettext("auth", "Failed to create session. Please try again."))
    |> redirect(to: ~p"/auth/login")
  end

  # Only an account created with an unproved email awaits verification, and
  # neither completion path creates one any more; one made before that change
  # is answered as a provider sign-in to it would be.
  defp respond_to_completion({:verification_required, _conn, _provider, _delivery} = result),
    do: respond_to_oauth_result(result, success_path: ~p"/dashboard", login_path: ~p"/auth/login")

  defp completion_failed(conn, :registration_disabled, _pending) do
    conn
    |> put_flash(:info, AuthActions.registration_disabled_message())
    |> redirect(to: ~p"/auth/login")
  end

  defp completion_failed(conn, :missing_pending_registration, _pending) do
    OAuthFlow.log_social_auth("unknown", false, conn, %{
      error_reason: "missing_pending_registration"
    })

    conn
    |> put_flash(
      :error,
      dgettext("auth", "Missing OAuth provider information. Please try again.")
    )
    |> redirect(to: ~p"/auth/login")
  end

  defp completion_failed(conn, :unsupported_provider, pending) do
    log_completion_failure(conn, pending, "unsupported_provider")

    conn
    |> delete_session(:pending_oauth_registration)
    |> put_flash(:error, dgettext("auth", "Unsupported OAuth provider."))
    |> redirect(to: ~p"/auth/login")
  end

  defp completion_failed(conn, {:provider_disabled, provider}, pending) do
    log_completion_failure(conn, pending, "provider_disabled")

    conn
    |> delete_session(:pending_oauth_registration)
    |> disabled_redirect(provider)
  end

  defp completion_failed(conn, :registration_expired, pending) do
    log_completion_failure(conn, pending, "registration_expired")

    conn
    |> delete_session(:pending_oauth_registration)
    |> put_flash(
      :error,
      dgettext("auth", "Your sign-up session has expired. Please sign in again.")
    )
    |> redirect(to: ~p"/auth/login")
  end

  defp completion_failed(conn, reason, pending)
       when is_atom(reason) and
              reason in [
                :email_required,
                :invalid_email,
                :terms_not_accepted,
                :email_already_taken
              ] do
    log_completion_failure(conn, pending, "validation_failed")
    redirect_to_registration_with_error(conn, reason)
  end

  defp completion_failed(conn, reason, pending) do
    log_completion_failure(conn, pending, "creation_failed")
    handle_oauth_creation_error(conn, reason)
  end

  defp log_completion_failure(conn, pending, error_reason) do
    OAuthFlow.log_social_auth(pending[:provider], false, conn, %{
      email: pending[:email],
      error_reason: error_reason
    })
  end

  @spec handle_oauth_creation_error(Plug.Conn.t(), any()) :: Plug.Conn.t()
  defp handle_oauth_creation_error(conn, reason) do
    Logger.error("Failed to create user from OAuth completion", reason: inspect(reason))

    # If this is a validation error, redirect back to registration with the data
    case reason do
      %Ecto.Changeset{} ->
        redirect_to_registration_with_error(conn, reason)

      _other_error ->
        AuthControllerHelpers.oauth_error_response(conn, reason, ~p"/auth/login")
    end
  end

  @spec redirect_to_registration_with_error(Plug.Conn.t(), any()) :: Plug.Conn.t()
  defp redirect_to_registration_with_error(conn, error) do
    query_params = %{"error" => AuthControllerHelpers.format_oauth_error_for_params(error)}

    conn
    |> put_flash(:error, AuthControllerHelpers.format_oauth_error_for_flash(error))
    |> redirect(to: ~p"/auth/complete-registration?#{query_params}")
  end

  @spec get_welcome_message(provider()) :: String.t()
  defp get_welcome_message(provider) do
    dgettext("auth", "Welcome! You've successfully signed up with %{provider}.",
      provider: provider_name(provider)
    )
  end

  @spec respond_to_oauth_result(
          OAuthFlow.flow_result(),
          keyword()
        ) :: Plug.Conn.t()
  defp respond_to_oauth_result({:ok, authed_conn, provider}, paths) do
    authed_conn
    |> put_flash(
      :info,
      dgettext("auth", "Successfully signed in with %{provider}.",
        provider: provider_name(provider)
      )
    )
    |> redirect(to: paths[:success_path])
  end

  defp respond_to_oauth_result({:verification_required, conn, _provider, delivery}, _paths) do
    {level, message} =
      case delivery do
        :sent ->
          {:info,
           dgettext(
             "auth",
             "Please verify your email address before signing in. We've sent you a new verification link."
           )}

        :rate_limited ->
          {:error, dgettext("auth", "Too many verification attempts. Please try again later.")}

        :failed ->
          {:error,
           dgettext(
             "auth",
             "Please verify your email address before signing in. We could not send a new verification link; please try again later."
           )}
      end

    conn
    |> put_flash(level, message)
    |> redirect(to: ~p"/auth/verify-email")
  end

  defp respond_to_oauth_result({:registration_required, state_conn, _provider, data}, _paths) do
    state_conn
    |> put_session(:pending_oauth_registration, data)
    |> redirect(to: ~p"/auth/complete-registration")
  end

  defp respond_to_oauth_result({:error, :invalid_state, flow_conn}, paths) do
    flow_conn
    |> put_flash(:error, dgettext("auth", "Security validation failed. Please try again."))
    |> redirect(to: paths[:login_path])
  end

  defp respond_to_oauth_result({:error, :oauth_error, provider, flow_conn}, paths) do
    flow_conn
    |> put_flash(
      :error,
      dgettext("auth", "Failed to authenticate with %{provider}.",
        provider: provider_name(provider)
      )
    )
    |> redirect(to: paths[:login_path])
  end

  defp respond_to_oauth_result({:error, :general_error, provider, flow_conn}, paths) do
    flow_conn
    |> put_flash(
      :error,
      dgettext("auth", "An error occurred during %{provider} authentication.",
        provider: provider_name(provider)
      )
    )
    |> redirect(to: paths[:login_path])
  end

  defp respond_to_oauth_result({:error, :session_failed, provider, flow_conn}, paths) do
    flow_conn
    |> put_flash(
      :error,
      dgettext(
        "auth",
        "%{provider} authentication succeeded but session creation failed.",
        provider: provider_name(provider)
      )
    )
    |> redirect(to: paths[:login_path])
  end

  defp respond_to_oauth_result({:error, :registration_disabled, _provider, flow_conn}, paths) do
    flow_conn
    |> put_flash(:info, AuthActions.registration_disabled_message())
    |> redirect(to: paths[:login_path])
  end

  defp respond_to_oauth_result({:error, :email_already_taken, _provider, flow_conn}, paths) do
    AuthControllerHelpers.oauth_error_response(
      flow_conn,
      :email_already_taken,
      paths[:login_path]
    )
  end

  @spec provider_name(provider() | String.t()) :: String.t()

  defp provider_name(provider), do: Providers.name(provider)

  @spec get_redirect_paths(Plug.Conn.t()) :: keyword()
  defp get_redirect_paths(conn) do
    configured_success_path = Config.success_redirect_path()

    success_path =
      RedirectSanitizer.sanitize(conn.params["success_path"], configured_success_path)

    login_path = ~p"/?auth=login"

    [success_path: success_path, login_path: login_path]
  end

  @spec get_login_path(Plug.Conn.t()) :: String.t()
  defp get_login_path(conn) do
    RedirectSanitizer.sanitize(conn.params["login_path"], ~p"/auth/login")
  end

  defp validate_oauth_provider(provider) do
    case Providers.parse(provider) do
      {:ok, provider_atom} -> {:ok, provider_atom}
      {:error, :unsupported_provider} -> {:error, :unsupported_oauth_provider}
    end
  end
end
