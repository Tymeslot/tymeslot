defmodule TymeslotWeb.SessionController do
  @moduledoc """
  Handles user session management including login and logout.
  """

  use TymeslotWeb, :controller

  alias Tymeslot.Auth
  alias Tymeslot.Auth.{Authentication, Session, Verification}
  alias Tymeslot.Infrastructure.Config
  alias TymeslotWeb.Helpers.ClientIP

  require Logger

  @doc """
  Creates a new session for the user after authentication.
  This is called by LiveView after successful authentication to establish HTTP session.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"email" => email, "password" => password} = params) do
    ip = ClientIP.get(conn)
    user_agent = List.first(get_req_header(conn, "user-agent"))

    case Authentication.authenticate_user(email, password,
           calling_app: :auth,
           ip_address: ip,
           user_agent: user_agent
         ) do
      {:ok, user, message} ->
        case Session.create_session(conn, user) do
          {:ok, updated_conn, _token} ->
            redirect_path = params["redirect_to"] || get_success_redirect_path()

            updated_conn
            |> put_flash(:info, message)
            |> redirect(to: redirect_path)

          {:error, _reason, details} ->
            Logger.error("Failed to create session: #{details}")

            conn
            |> put_flash(:error, "Failed to create session. Please try again.")
            |> redirect(to: "/auth/login")
        end

      {:error, :email_not_verified, message} ->
        # Store unverified user info in session for resend functionality
        conn
        |> put_session(:unverified_user_id, get_unverified_user_id(email))
        |> put_session(:unverified_user_email, email)
        |> put_session(:unverified_session_timestamp, DateTime.to_unix(DateTime.utc_now()))
        |> put_flash(:error, message)
        |> redirect(to: "/auth/verify-email")

      {:error, _reason, message} ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: "/auth/login")
    end
  end

  @doc """
  Logs out the current user by clearing their session.
  """
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> Auth.delete_session()
    |> clear_unverified_session()
    |> put_flash(:info, "Logged out successfully.")
    |> redirect(to: ~p"/")
  end

  @doc """
  Completes email verification and creates session for auto-login if IP matches.
  """
  @spec verify_and_login(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def verify_and_login(conn, %{"token" => token}) do
    current_ip = extract_request_ip(conn)

    # First, get the user with the token to check the IP before it's cleared
    case Config.user_queries_module().get_user_by_verification_token(token) do
      {:error, :not_found} ->
        conn
        |> put_flash(:error, "The email verification link is invalid or has expired.")
        |> redirect(to: "/auth/login")

      {:ok, user_before_verification} ->
        # Check if IP matches to decide whether to auto-login after verification.
        should_auto_login = check_ip_match(user_before_verification, current_ip)

        # Now verify the user
        case Verification.verify_user_token(token) do
          {:ok, verified_user} ->
            handle_verified_user(
              conn,
              verified_user,
              should_auto_login,
              user_before_verification,
              current_ip
            )

          {:error, reason} ->
            Logger.error("Invalid email verification token: #{inspect(reason)}")

            conn
            |> put_flash(:error, "The email verification link is invalid or has expired.")
            |> redirect(to: "/auth/login")
        end
    end
  end

  # Private functions

  defp get_success_redirect_path do
    Config.success_redirect_path()
  end

  defp get_unverified_user_id(email) do
    case Config.user_queries_module().get_user_by_email(email) do
      {:ok, user} -> user.id
      {:error, :not_found} -> nil
      # Backward compatibility with implementations that still return user or nil
      nil -> nil
      user when is_map(user) -> Map.get(user, :id)
      _ -> nil
    end
  end

  defp clear_unverified_session(conn) do
    conn
    |> delete_session(:unverified_user_id)
    |> delete_session(:unverified_user_email)
    |> delete_session(:unverified_session_timestamp)
  end

  defp extract_request_ip(conn) do
    ClientIP.get(conn)
  end

  defp check_ip_match(user, current_ip) do
    case user.signup_ip do
      nil ->
        false

      signup_ip ->
        # Normalize localhost variations
        normalized_signup = normalize_localhost_ip(signup_ip)
        normalized_current = normalize_localhost_ip(current_ip)

        normalized_signup == normalized_current
    end
  end

  defp normalize_localhost_ip(ip) do
    case ip do
      "127.0.0.1" -> "localhost"
      # IPv6 localhost
      "::1" -> "localhost"
      # IPv6 localhost expanded
      "0:0:0:0:0:0:0:1" -> "localhost"
      other -> other
    end
  end

  defp handle_verified_user(
         conn,
         verified_user,
         should_auto_login,
         _user_before_verification,
         _current_ip
       ) do
    if should_auto_login do
      Logger.info(
        "Auto-login approved for user #{verified_user.id} - IP match confirmed"
      )

      case Session.create_session(conn, verified_user) do
        {:ok, updated_conn, _token} ->
          updated_conn
          |> clear_unverified_session()
          |> put_flash(
            :success,
            "Your email has been successfully verified! You're now logged in."
          )
          |> redirect(to: get_success_redirect_path())

        {:error, _reason, details} ->
          Logger.error("Failed to create session after verification: #{details}")

          conn
          |> put_flash(
            :info,
            "Your email has been successfully verified! Please log in to continue."
          )
          |> redirect(to: "/auth/login")
      end
    else
      Logger.info(
        "Auto-login denied for user #{verified_user.id} - IP mismatch"
      )

      conn
      |> put_flash(:info, "Your email has been successfully verified! Please log in to continue.")
      |> redirect(to: "/auth/login")
    end
  end
end
