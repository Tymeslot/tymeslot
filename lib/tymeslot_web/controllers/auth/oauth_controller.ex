defmodule TymeslotWeb.OAuthController do
  @moduledoc """
  Handles OAuth authentication flows for GitHub and Google.
  """

  use TymeslotWeb, :controller
  require Logger

  alias Tymeslot.Auth.OAuth.GitHub
  alias Tymeslot.Auth.OAuth.Google
  alias Tymeslot.Auth.OAuth.Helper, as: OAuthHelper
  alias Tymeslot.Auth.OAuth.URLs
  alias Tymeslot.Auth.{Session, SocialAuthentication, Verification}
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.AuthControllerHelpers
  alias TymeslotWeb.Helpers.ClientIP

  @doc """
  Generic OAuth request handler that dispatches to provider-specific functions.
  Checks if social authentication is enabled for the provider when used for auth.
  """
  @spec request(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def request(conn, %{"provider" => "github"} = params),
    do: dispatch_request(conn, :github, params)

  def request(conn, %{"provider" => "google"} = params),
    do: dispatch_request(conn, :google, params)

  def request(conn, %{"provider" => provider}) do
    conn
    |> put_flash(:error, "Unsupported OAuth provider: #{provider}")
    |> redirect(to: "/auth/login")
  end

  def request(conn, _params) do
    conn
    |> put_flash(:error, "OAuth authentication failed - missing provider.")
    |> redirect(to: "/auth/login")
  end

  defp dispatch_request(conn, provider_atom, params) do
    intent = get_session(conn, :oauth_intent) || :authentication

    case intent do
      :authentication ->
        if social_auth_enabled?(provider_atom) do
          do_provider_auth(conn, provider_atom, params)
        else
          disabled_redirect(conn, provider_atom)
        end

      _ ->
        do_provider_auth(conn, provider_atom, params)
    end
  end

  defp social_auth_enabled?(provider_atom) do
    social_auth_config = Application.get_env(:tymeslot, :social_auth, [])

    case provider_atom do
      :github -> Keyword.get(social_auth_config, :github_enabled, false)
      :google -> Keyword.get(social_auth_config, :google_enabled, false)
    end
  end

  defp do_provider_auth(conn, :github, params), do: github_auth(conn, params)
  defp do_provider_auth(conn, :google, params), do: google_auth(conn, params)

  defp disabled_redirect(conn, provider_atom) do
    provider_name =
      case provider_atom do
        :github -> "GitHub"
        :google -> "Google"
      end

    conn
    |> put_flash(:error, "#{provider_name} authentication is not available")
    |> redirect(to: "/auth/login")
  end

  @doc """
  Initiates GitHub OAuth authentication flow.
  """
  @spec github_auth(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def github_auth(conn, _params) do
    case RateLimiter.check_oauth_initiation_rate_limit(ClientIP.get(conn)) do
      :ok ->
        redirect_uri = URLs.callback_url(conn, "/auth/github/callback")
        {updated_conn, authorize_url} = GitHub.authorize_url(conn, redirect_uri)
        redirect(updated_conn, external: authorize_url)

      {:error, :rate_limited, _message} ->
        AuthControllerHelpers.handle_rate_limited(
          conn,
          "Too many OAuth attempts. Please try again later.",
          "/auth/login"
        )
    end
  end

  @doc """
  Initiates Google OAuth authentication flow.
  """
  @spec google_auth(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def google_auth(conn, _params) do
    case RateLimiter.check_oauth_initiation_rate_limit(ClientIP.get(conn)) do
      :ok ->
        redirect_uri = URLs.callback_url(conn, "/auth/google/callback")
        {updated_conn, authorize_url} = Google.authorize_url(conn, redirect_uri)
        redirect(updated_conn, external: authorize_url)

      {:error, :rate_limited, _message} ->
        AuthControllerHelpers.handle_rate_limited(
          conn,
          "Too many OAuth attempts. Please try again later.",
          "/auth/login"
        )
    end
  end

  @doc """
  Generic OAuth callback handler that dispatches to provider-specific functions.
  """
  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, %{"provider" => "github"} = params) do
    github_callback(conn, Map.delete(params, "provider"))
  end

  def callback(conn, %{"provider" => "google"} = params) do
    google_callback(conn, Map.delete(params, "provider"))
  end

  def callback(conn, %{"provider" => provider}) do
    login_path = get_login_path(conn)

    conn
    |> put_flash(:error, "Unsupported OAuth provider: #{provider}")
    |> redirect(to: login_path)
  end

  def callback(conn, _params) do
    login_path = get_login_path(conn)

    conn
    |> put_flash(:error, "OAuth authentication failed - missing provider.")
    |> redirect(to: login_path)
  end

  @doc """
  Handles GitHub OAuth callback.
  """
  @spec github_callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def github_callback(conn, %{"code" => code, "state" => state}) do
    case RateLimiter.check_oauth_callback_rate_limit(ClientIP.get(conn)) do
      :ok ->
        paths = get_redirect_paths(conn)
        # Clear the oauth_intent session after handling
        conn
        |> delete_session(:oauth_intent)
        |> OAuthHelper.handle_oauth_callback(code, state, :github, paths)

      {:error, :rate_limited, _message} ->
        AuthControllerHelpers.handle_rate_limited(
          conn,
          "Too many authentication attempts. Please try again later.",
          get_login_path(conn)
        )
    end
  end

  def github_callback(conn, %{"code" => code}) do
    case RateLimiter.check_oauth_callback_rate_limit(ClientIP.get(conn)) do
      :ok ->
        # Handle legacy callbacks without state parameter (less secure)
        Logger.warning("GitHub OAuth callback received without state parameter")
        paths = get_redirect_paths(conn)
        # Clear the oauth_intent session after handling
        conn
        |> delete_session(:oauth_intent)
        |> OAuthHelper.handle_oauth_callback(code, :github, paths)

      {:error, :rate_limited, _message} ->
        AuthControllerHelpers.handle_rate_limited(
          conn,
          "Too many authentication attempts. Please try again later.",
          get_login_path(conn)
        )
    end
  end

  def github_callback(conn, _params) do
    conn
    |> put_flash(:error, "GitHub authentication failed - missing authorization code.")
    |> redirect(to: "/?auth=login")
  end

  @doc """
  Handles Google OAuth callback.
  """
  @spec google_callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def google_callback(conn, %{"code" => code, "state" => state}) do
    case RateLimiter.check_oauth_callback_rate_limit(ClientIP.get(conn)) do
      :ok ->
        paths = get_redirect_paths(conn)
        # Clear the oauth_intent session after handling
        conn
        |> delete_session(:oauth_intent)
        |> OAuthHelper.handle_oauth_callback(code, state, :google, paths)

      {:error, :rate_limited, _message} ->
        AuthControllerHelpers.handle_rate_limited(
          conn,
          "Too many authentication attempts. Please try again later.",
          get_login_path(conn)
        )
    end
  end

  def google_callback(conn, %{"code" => code}) do
    case RateLimiter.check_oauth_callback_rate_limit(ClientIP.get(conn)) do
      :ok ->
        # Handle legacy callbacks without state parameter (less secure)
        Logger.warning("Google OAuth callback received without state parameter")
        paths = get_redirect_paths(conn)
        # Clear the oauth_intent session after handling
        conn
        |> delete_session(:oauth_intent)
        |> OAuthHelper.handle_oauth_callback(code, :google, paths)

      {:error, :rate_limited, _message} ->
        AuthControllerHelpers.handle_rate_limited(
          conn,
          "Too many authentication attempts. Please try again later.",
          get_login_path(conn)
        )
    end
  end

  def google_callback(conn, _params) do
    conn
    |> put_flash(:error, "Google authentication failed - missing authorization code.")
    |> redirect(to: "/?auth=login")
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
          "Too many registration attempts. Please try again later.",
          "/auth/login"
        )
    end
  end

  # Private helper functions

  defp process_oauth_completion(conn, params) do
    oauth_data = build_oauth_data(params)
    profile_params = build_profile_params(params)

    if is_nil(oauth_data.provider) do
      conn
      |> put_flash(:error, "Missing OAuth provider information. Please try again.")
      |> redirect(to: "/auth/login")
    else
      handle_oauth_with_provider(conn, oauth_data, params, profile_params)
    end
  end

  defp handle_oauth_with_provider(conn, oauth_data, params, profile_params) do
    provider =
      case oauth_data.provider do
        "github" -> :github
        "google" -> :google
        other -> String.to_existing_atom(other)
      end

    case validate_oauth_completion_data(oauth_data) do
      :ok ->
        case OAuthHelper.create_oauth_user(provider, oauth_data, profile_params) do
          {:ok, user} ->
            handle_oauth_user_creation(conn, user, oauth_data)

          {:error, reason} ->
            handle_oauth_creation_error(conn, reason, params)
        end

      {:error, validation_error} ->
        handle_oauth_validation_error(conn, validation_error, params)
    end
  end

  @spec build_oauth_data(map()) :: map()
  defp build_oauth_data(params) do
    email_from_provider = params["oauth_email_from_provider"] == "true"

    # Email can come from form submission (auth[email]) or OAuth redirect (oauth_email)
    email =
      case get_in(params, ["auth", "email"]) do
        nil -> params["oauth_email"]
        form_email -> form_email
      end

    %{
      provider: params["oauth_provider"],
      email: email,
      is_verified: params["oauth_verified"] == "true",
      email_from_provider: email_from_provider,
      github_user_id: params["oauth_github_id"],
      google_user_id: params["oauth_google_id"],
      name: params["oauth_name"] || ""
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
    if Map.get(user, :needs_email_verification, false) do
      handle_email_verification_flow(conn, user, oauth_data)
    else
      create_session_and_redirect(
        conn,
        user,
        oauth_data,
        get_welcome_message(oauth_data.provider)
      )
    end
  end

  @spec handle_email_verification_flow(Plug.Conn.t(), map(), map()) :: Plug.Conn.t()
  defp handle_email_verification_flow(conn, user, oauth_data) do
    case Verification.verify_user_email(conn, user, %{}) do
      {:ok, _updated_user} ->
        message =
          "Welcome! Successfully signed up with #{String.capitalize(oauth_data.provider)}. Please check your email to verify your account."

        create_session_and_redirect(conn, user, oauth_data, message)

      {:error, :rate_limited, _message} ->
        handle_rate_limited_error(conn)

      {:error, _reason} ->
        message =
          "Welcome! Successfully signed up with #{String.capitalize(oauth_data.provider)}. Verification email could not be sent - please contact support if needed."

        create_session_and_redirect(conn, user, oauth_data, message)
    end
  end

  @spec create_session_and_redirect(Plug.Conn.t(), map(), map(), String.t()) :: Plug.Conn.t()
  defp create_session_and_redirect(conn, user, _oauth_data, success_message) do
    case Session.create_session(conn, user) do
      {:ok, updated_conn, _token} ->
        updated_conn
        |> put_flash(:info, success_message)
        |> redirect(to: "/dashboard")

      {:error, _reason, _details} ->
        conn
        |> put_flash(:error, "Failed to create session. Please try again.")
        |> redirect(to: "/auth/login")
    end
  end

  @spec handle_oauth_creation_error(Plug.Conn.t(), any(), map()) :: Plug.Conn.t()
  defp handle_oauth_creation_error(conn, reason, params) do
    Logger.error("Failed to create user from OAuth completion: #{inspect(reason)}")

    # If this is a validation error, redirect back to registration with the data
    case reason do
      %Ecto.Changeset{} ->
        redirect_to_registration_with_error(conn, reason, params)

      _ ->
        oauth_error_response(conn, reason, "/auth/login")
    end
  end

  @spec handle_oauth_validation_error(Plug.Conn.t(), atom() | String.t(), map()) :: Plug.Conn.t()
  defp handle_oauth_validation_error(conn, validation_error, params) do
    redirect_to_registration_with_error(conn, validation_error, params)
  end

  @spec validate_oauth_completion_data(map()) :: :ok | {:error, atom() | String.t()}
  defp validate_oauth_completion_data(oauth_data) do
    email = oauth_data.email

    cond do
      is_nil(email) or String.trim(email) == "" ->
        {:error, :email_required}

      not valid_email_format?(email) ->
        {:error, :invalid_email}

      true ->
        # Check if email already exists in database
        case SocialAuthentication.check_email_availability(email) do
          :ok -> :ok
          {:error, message} -> {:error, message}
        end
    end
  end

  @spec valid_email_format?(String.t()) :: boolean()
  defp valid_email_format?(email) when is_binary(email) do
    # Basic email validation regex
    email_regex = ~r/^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/
    Regex.match?(email_regex, email)
  end

  @spec redirect_to_registration_with_error(Plug.Conn.t(), any(), map()) :: Plug.Conn.t()
  defp redirect_to_registration_with_error(conn, error, params) do
    # Fix the email_from_provider flag when email is actually missing/empty
    email = params["oauth_email"]
    email_actually_provided = email && String.trim(email) != ""

    # Build query params to maintain OAuth data and show error
    query_params =
      params
      |> Map.take([
        "oauth_provider",
        "oauth_verified",
        "oauth_email",
        "oauth_github_id",
        "oauth_google_id",
        "oauth_name"
      ])
      |> Map.put("oauth_email_from_provider", to_string(email_actually_provided))
      |> Map.put("error", format_error_for_params(error))
      |> URI.encode_query()

    conn
    |> put_flash(:error, format_error_for_flash(error))
    |> redirect(to: "/auth/complete-registration?#{query_params}")
  end

  @spec format_error_for_flash(any()) :: String.t()
  defp format_error_for_flash(%Ecto.Changeset{} = changeset) do
    case changeset.errors do
      [email: {"can't be blank", _}] ->
        "Email address is required to complete registration."

      [email: {message, _}] when is_binary(message) ->
        "Email #{message}. Please provide a valid email address."

      _ ->
        "Registration failed due to validation errors. Please check your information and try again."
    end
  end

  defp format_error_for_flash(:email_required),
    do: "Email address is required to complete registration."

  defp format_error_for_flash(:invalid_email), do: "Please provide a valid email address."
  defp format_error_for_flash(error_message) when is_binary(error_message), do: error_message

  @spec format_error_for_params(any()) :: String.t()
  defp format_error_for_params(%Ecto.Changeset{}), do: "validation_failed"
  defp format_error_for_params(:email_required), do: "email_required"
  defp format_error_for_params(:invalid_email), do: "invalid_email"

  defp format_error_for_params(error_message) when is_binary(error_message),
    do: "email_already_taken"

  @spec handle_rate_limited_error(Plug.Conn.t()) :: Plug.Conn.t()
  defp handle_rate_limited_error(conn) do
    AuthControllerHelpers.handle_rate_limited(
      conn,
      "Too many verification attempts. Please try again later.",
      "/auth/login"
    )
  end

  @spec get_welcome_message(String.t()) :: String.t()
  defp get_welcome_message(provider) do
    "Welcome! Successfully signed up with #{String.capitalize(provider)}."
  end

  @spec get_redirect_paths(Plug.Conn.t()) :: keyword()
  defp get_redirect_paths(conn) do
    configured_success_path = Application.get_env(:tymeslot, :auth)[:success_redirect_path]

    success_path = sanitize_redirect_path(conn.params["success_path"], configured_success_path)
    # For security failures (invalid state, etc.), use the security failure path
    login_path = "/?auth=login"

    registration_path =
      sanitize_redirect_path(conn.params["registration_path"], "/auth/complete-registration")

    [
      success_path: success_path,
      login_path: login_path,
      registration_path: registration_path
    ]
  end

  defp sanitize_redirect_path(path, default) do
    case path do
      p when is_binary(p) ->
        if String.starts_with?(p, "/") and not String.contains?(p, "://") and
             not String.starts_with?(p, "//") do
          p
        else
          default
        end

      _ ->
        default
    end
  end

  @spec get_login_path(Plug.Conn.t()) :: String.t()
  defp get_login_path(conn) do
    conn.params["login_path"] || "/auth/login"
  end

  @spec oauth_error_response(Plug.Conn.t(), any(), String.t()) :: Plug.Conn.t()
  defp oauth_error_response(conn, reason, redirect_path) do
    error_message =
      case reason do
        %Ecto.Changeset{} = changeset ->
          format_changeset_errors(changeset)

        :user_creation_failed ->
          "Failed to create user account. Please try again."

        :invalid_oauth_data ->
          "Invalid OAuth data received. Please try again."

        :email_required ->
          "Email address is required to complete registration. Please provide your email address."

        :invalid_email ->
          "Please provide a valid email address."

        :email_already_taken ->
          "This email address is already associated with another account. Please use a different email or sign in to your existing account."

        _ ->
          "Authentication failed. Please try again."
      end

    conn
    |> put_flash(:error, error_message)
    |> redirect(to: redirect_path)
  end

  defp format_changeset_errors(%Ecto.Changeset{errors: errors}) do
    case errors do
      [email: {"can't be blank", _}] ->
        "Email address is required to complete registration."

      [email: {message, _}] when is_binary(message) ->
        "Email #{message}. Please provide a valid email address."

      _ ->
        "Registration failed due to validation errors. Please check your information and try again."
    end
  end
end
