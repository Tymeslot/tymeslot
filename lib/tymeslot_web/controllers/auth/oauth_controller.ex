defmodule TymeslotWeb.OAuthController do
  @moduledoc """
  Handles OAuth authentication flows for GitHub, Google, and generic
  OAuth/OIDC SSO providers.
  """

  use TymeslotWeb, :controller
  use Gettext, backend: TymeslotWeb.Gettext
  require Logger

  alias Tymeslot.Auth.{AuthActions, Session, Verification}
  alias Tymeslot.Auth.OAuth.{GenericOAuth, GitHub, Google}
  alias Tymeslot.Auth.OAuth.Helper, as: OAuthHelper
  alias Tymeslot.Auth.OAuth.{URLs, UserRegistration}
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.AuthControllerHelpers
  alias TymeslotWeb.Helpers.{ClientIP, RedirectSanitizer}

  @doc """
  Generic OAuth request handler that dispatches to provider-specific functions.
  Checks if social authentication is enabled for the provider when used for auth.
  """
  @spec request(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def request(conn, %{"provider" => "github"} = params),
    do: dispatch_request(conn, :github, params)

  def request(conn, %{"provider" => "google"} = params),
    do: dispatch_request(conn, :google, params)

  def request(conn, %{"provider" => "oauth"} = params),
    do: dispatch_request(conn, :oauth, params)

  def request(conn, %{"provider" => provider}) do
    conn
    |> put_flash(
      :error,
      dgettext("auth", "Unsupported OAuth provider: %{provider}", provider: provider)
    )
    |> redirect(to: ~p"/auth/login")
  end

  def request(conn, _params) do
    conn
    |> put_flash(:error, dgettext("auth", "OAuth authentication failed - missing provider."))
    |> redirect(to: ~p"/auth/login")
  end

  defp dispatch_request(conn, provider_atom, params) do
    if social_auth_enabled?(provider_atom) do
      do_provider_auth(conn, provider_atom, params)
    else
      disabled_redirect(conn, provider_atom)
    end
  end

  defp social_auth_enabled?(provider_atom) do
    social_auth_config = Application.get_env(:tymeslot, :social_auth, [])

    case provider_atom do
      :github -> Keyword.get(social_auth_config, :github_enabled, false)
      :google -> Keyword.get(social_auth_config, :google_enabled, false)
      :oauth -> Keyword.get(social_auth_config, :oauth_enabled, false)
    end
  end

  defp do_provider_auth(conn, provider, _params) do
    case RateLimiter.check_oauth_initiation_rate_limit(ClientIP.get(conn)) do
      :ok ->
        redirect_uri = URLs.callback_url(conn, URLs.callback_path(provider))

        {updated_conn, authorize_url} =
          provider_module(provider).authorize_url(conn, redirect_uri)

        redirect(updated_conn, external: authorize_url)

      {:error, :rate_limited, _message} ->
        AuthControllerHelpers.handle_rate_limited(
          conn,
          dgettext("auth", "Too many OAuth attempts. Please try again later."),
          ~p"/auth/login"
        )
    end
  end

  defp oauth_callback_module,
    do: Application.get_env(:tymeslot, :oauth_callback_module, OAuthHelper)

  defp provider_module(:github), do: GitHub
  defp provider_module(:google), do: Google
  defp provider_module(:oauth), do: GenericOAuth

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
        handle_provider_callback(conn, provider_atom, code, state)

      {:error, :unsupported_oauth_provider} ->
        conn
        |> put_flash(
          :error,
          dgettext("auth", "Unsupported OAuth provider: %{provider}", provider: provider)
        )
        |> redirect(to: get_login_path(conn))
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
        conn
        |> put_flash(
          :error,
          dgettext("auth", "Unsupported OAuth provider: %{provider}", provider: provider)
        )
        |> redirect(to: get_login_path(conn))
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
    case RateLimiter.check_oauth_completion_rate_limit(ClientIP.get(conn)) do
      :ok ->
        process_oauth_completion(conn, params)

      {:error, :rate_limited, _message} ->
        AuthControllerHelpers.handle_rate_limited(
          conn,
          dgettext("auth", "Too many registration attempts. Please try again later."),
          ~p"/auth/login"
        )
    end
  end

  # Private helper functions

  defp handle_provider_callback(conn, provider, code, state) do
    case RateLimiter.check_oauth_callback_rate_limit(ClientIP.get(conn)) do
      :ok ->
        paths = get_redirect_paths(conn)

        conn
        |> delete_session(:oauth_intent)
        |> oauth_callback_module().handle_oauth_callback(%{
          code: code,
          state: state,
          provider: provider
        })
        |> respond_to_oauth_result(paths)

      {:error, :rate_limited, _message} ->
        AuthControllerHelpers.handle_rate_limited(
          conn,
          dgettext("auth", "Too many authentication attempts. Please try again later."),
          get_login_path(conn)
        )
    end
  end

  defp process_oauth_completion(conn, params) do
    if Config.registration_enabled?() do
      do_process_oauth_completion(conn, params)
    else
      conn
      |> put_flash(:info, AuthActions.registration_disabled_message())
      |> redirect(to: ~p"/auth/login")
    end
  end

  defp do_process_oauth_completion(conn, params) do
    case get_session(conn, :pending_oauth_registration) do
      nil ->
        conn
        |> put_flash(
          :error,
          dgettext("auth", "Missing OAuth provider information. Please try again.")
        )
        |> redirect(to: ~p"/auth/login")

      session_data ->
        oauth_data = build_oauth_data_from_session(session_data, params)
        profile_params = build_profile_params(params)
        handle_oauth_with_provider(conn, oauth_data, params, profile_params)
    end
  end

  defp handle_oauth_with_provider(conn, oauth_data, params, profile_params) do
    case validate_oauth_provider(oauth_data.provider) do
      {:ok, provider} ->
        metadata = %{
          ip: ClientIP.get(conn),
          user_agent: ClientIP.get_user_agent(conn),
          source: "oauth_signup",
          terms_accepted: oauth_data.terms_accepted
        }

        case UserRegistration.validate_completion_data(oauth_data) do
          :ok ->
            case UserRegistration.create_oauth_user(provider, oauth_data, profile_params,
                   metadata: metadata
                 ) do
              {:ok, user} ->
                handle_oauth_user_creation(conn, user, oauth_data)

              {:error, reason} ->
                handle_oauth_creation_error(conn, reason, params)
            end

          {:error, validation_error} ->
            handle_oauth_validation_error(conn, validation_error, params)
        end

      {:error, :unsupported_oauth_provider} ->
        conn
        |> delete_session(:pending_oauth_registration)
        |> put_flash(:error, dgettext("auth", "Unsupported OAuth provider."))
        |> redirect(to: ~p"/auth/login")
    end
  end

  @spec build_oauth_data_from_session(map(), map()) :: map()
  defp build_oauth_data_from_session(session_data, params) do
    # User-editable fields come from the form submission; everything else from the session
    email =
      if session_data[:email_from_provider] do
        session_data[:email]
      else
        get_in(params, ["auth", "email"]) || session_data[:email]
      end

    %{
      provider: session_data[:provider],
      email: email,
      is_verified: session_data[:is_verified] == true,
      email_from_provider: session_data[:email_from_provider] == true,
      github_user_id: session_data[:github_user_id],
      google_user_id: session_data[:google_user_id],
      provider_uid: session_data[:provider_uid],
      name: session_data[:name] || "",
      terms_accepted: get_terms_accepted(params)
    }
  end

  @spec build_profile_params(map()) :: map()
  defp build_profile_params(params) do
    profile_data = params["profile"] || %{}

    %{
      full_name: profile_data["full_name"]
    }
  end

  @spec handle_oauth_user_creation(Plug.Conn.t(), map(), map()) :: Plug.Conn.t()
  defp handle_oauth_user_creation(conn, user, oauth_data) do
    conn = delete_session(conn, :pending_oauth_registration)

    if Map.get(user, :needs_email_verification, false) do
      handle_email_verification_flow(conn, user, oauth_data)
    else
      create_session_and_redirect(conn, user, get_welcome_message(oauth_data.provider))
    end
  end

  @spec handle_email_verification_flow(Plug.Conn.t(), map(), map()) :: Plug.Conn.t()
  defp handle_email_verification_flow(conn, user, oauth_data) do
    case Verification.verify_user_email(conn, user, %{}) do
      {:ok, _updated_user} ->
        message =
          dgettext(
            "auth",
            "Welcome! You've successfully signed up with %{provider}. Please check your email to verify your account.",
            provider: String.capitalize(oauth_data.provider)
          )

        create_session_and_redirect(conn, user, message)

      {:error, :rate_limited, _rate_limit_message} ->
        handle_rate_limited_error(conn)

      {:error, _error_reason} ->
        message =
          dgettext(
            "auth",
            "Welcome! You've successfully signed up with %{provider}. Verification email could not be sent - please contact support if needed.",
            provider: String.capitalize(oauth_data.provider)
          )

        create_session_and_redirect(conn, user, message)
    end
  end

  @spec create_session_and_redirect(Plug.Conn.t(), map(), String.t()) :: Plug.Conn.t()
  defp create_session_and_redirect(conn, user, success_message) do
    case Session.create_session(conn, user) do
      {:ok, updated_conn, _session_token} ->
        updated_conn
        |> put_flash(:info, success_message)
        |> redirect(to: ~p"/dashboard")

      {:error, _error_reason, _error_details} ->
        conn
        |> put_flash(:error, dgettext("auth", "Failed to create session. Please try again."))
        |> redirect(to: ~p"/auth/login")
    end
  end

  @spec handle_oauth_creation_error(Plug.Conn.t(), any(), map()) :: Plug.Conn.t()
  defp handle_oauth_creation_error(conn, reason, params) do
    Logger.error("Failed to create user from OAuth completion", reason: inspect(reason))

    # If this is a validation error, redirect back to registration with the data
    case reason do
      %Ecto.Changeset{} ->
        redirect_to_registration_with_error(conn, reason, params)

      _other_error ->
        AuthControllerHelpers.oauth_error_response(conn, reason, ~p"/auth/login")
    end
  end

  @spec handle_oauth_validation_error(Plug.Conn.t(), atom() | String.t(), map()) :: Plug.Conn.t()
  defp handle_oauth_validation_error(conn, validation_error, params) do
    redirect_to_registration_with_error(conn, validation_error, params)
  end

  @spec redirect_to_registration_with_error(Plug.Conn.t(), any(), map()) :: Plug.Conn.t()
  defp redirect_to_registration_with_error(conn, error, _params) do
    query_params = %{"error" => AuthControllerHelpers.format_oauth_error_for_params(error)}

    conn
    |> put_flash(:error, AuthControllerHelpers.format_oauth_error_for_flash(error))
    |> redirect(to: ~p"/auth/complete-registration?#{query_params}")
  end

  @spec handle_rate_limited_error(Plug.Conn.t()) :: Plug.Conn.t()
  defp handle_rate_limited_error(conn) do
    AuthControllerHelpers.handle_rate_limited(
      conn,
      dgettext("auth", "Too many verification attempts. Please try again later."),
      ~p"/auth/login"
    )
  end

  @spec get_welcome_message(String.t()) :: String.t()
  defp get_welcome_message(provider) do
    dgettext("auth", "Welcome! You've successfully signed up with %{provider}.",
      provider: String.capitalize(provider)
    )
  end

  @spec respond_to_oauth_result(
          Tymeslot.Auth.OAuth.HelperBehaviour.flow_result(),
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

  defp provider_name(:github), do: "GitHub"
  defp provider_name(:google), do: "Google"
  defp provider_name(:oauth), do: "SSO"

  @spec get_redirect_paths(Plug.Conn.t()) :: keyword()
  defp get_redirect_paths(conn) do
    configured_success_path = Application.get_env(:tymeslot, :auth)[:success_redirect_path]

    success_path =
      RedirectSanitizer.sanitize(conn.params["success_path"], configured_success_path)

    login_path = ~p"/?auth=login"

    [success_path: success_path, login_path: login_path]
  end

  @spec get_login_path(Plug.Conn.t()) :: String.t()
  defp get_login_path(conn) do
    RedirectSanitizer.sanitize(conn.params["login_path"], ~p"/auth/login")
  end

  @spec validate_oauth_provider(String.t() | nil) ::
          {:ok, :github | :google | :oauth} | {:error, :unsupported_oauth_provider}
  defp validate_oauth_provider(provider) do
    case provider do
      "github" -> {:ok, :github}
      "google" -> {:ok, :google}
      "oauth" -> {:ok, :oauth}
      _unsupported -> {:error, :unsupported_oauth_provider}
    end
  end

  defp get_terms_accepted(params) do
    case get_in(params, ["auth", "terms_accepted"]) || params["terms_accepted"] do
      true -> true
      "true" -> true
      "on" -> true
      _not_accepted -> false
    end
  end
end
