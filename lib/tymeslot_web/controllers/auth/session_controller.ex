defmodule TymeslotWeb.SessionController do
  @moduledoc """
  Handles user session management including login and logout.
  """

  use TymeslotWeb, :controller
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Auth
  alias Tymeslot.Infrastructure.Config
  alias TymeslotWeb.EmailLinkConfirmHTML
  alias TymeslotWeb.Helpers.{ClientIP, RedirectSanitizer}
  alias TymeslotWeb.UserAuth

  require Logger

  @doc """
  Creates a new session for the user after authentication.
  This is called by LiveView after successful authentication to establish HTTP session.
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"email" => email, "password" => password} = params) do
    case Auth.authenticate_user(email, password, ClientIP.request_opts(conn)) do
      {:ok, user, message} ->
        handle_authenticated_user(conn, user, message, params)

      {:error, :invalid_input, _errors} ->
        conn
        |> put_flash(:error, dgettext("auth", "Please enter your email and password."))
        |> redirect(to: ~p"/auth/login")

      {:error, _reason, message} ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: ~p"/auth/login")
    end
  end

  defp handle_authenticated_user(conn, user, message, params) do
    case UserAuth.create_session(conn, user) do
      {:ok, updated_conn, _token} ->
        redirect_path =
          RedirectSanitizer.sanitize(params["redirect_to"], get_success_redirect_path())

        updated_conn
        |> put_flash(:info, message)
        |> redirect(to: redirect_path)

      {:error, _reason, details} ->
        Logger.error("Failed to create session", details: details)

        conn
        |> put_flash(:error, dgettext("auth", "Failed to create session. Please try again."))
        |> redirect(to: ~p"/auth/login")
    end
  end

  @doc """
  Logs out the current user by clearing their session.
  """
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> UserAuth.delete_session()
    |> UserAuth.clear_unverified_user()
    |> put_flash(:info, dgettext("auth", "Logged out successfully."))
    |> redirect(to: ~p"/")
  end

  @doc """
  Landing page for the emailed verification link. Renders a confirmation
  button only: opening the link must not consume the token, or a mail scanner
  prefetching it would verify the address (and burn the link) on the user's
  behalf.
  """
  @spec confirm_verification(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm_verification(conn, %{"token" => token}) do
    conn
    |> put_layout(html: false)
    |> put_view(html: EmailLinkConfirmHTML)
    |> render(:confirm,
      action: ~p"/auth/verify-complete/#{token}",
      icon: "hero-envelope",
      title: dgettext("auth", "Confirm your email address"),
      body: dgettext("auth", "Press the button below to finish verifying your email address."),
      button: dgettext("auth", "Verify email address")
    )
  end

  @doc """
  Completes email verification, signing the user in when the context allows
  it (see `Tymeslot.Auth.verify_email_and_maybe_login/2`).
  """
  @spec verify_and_login(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def verify_and_login(conn, %{"token" => token}) do
    case Auth.verify_email_and_maybe_login(token, ClientIP.get(conn)) do
      {:ok, user, :auto_login} ->
        auto_login(conn, user)

      {:ok, user, :manual} ->
        Logger.info("Auto-login denied - IP mismatch", user_id: user.id)
        redirect_to_login_verified(conn)

      {:error, :token_expired} ->
        conn
        |> put_flash(:error, link_expired_message())
        |> redirect(to: ~p"/auth/login")

      {:error, reason} ->
        Logger.warning("Email verification link rejected", reason: inspect(reason))

        conn
        |> put_flash(:error, link_superseded_message())
        |> redirect(to: ~p"/auth/login")
    end
  end

  # Private functions

  defp auto_login(conn, user) do
    Logger.info("Auto-login approved - IP match confirmed", user_id: user.id)

    case UserAuth.create_session(conn, user) do
      {:ok, updated_conn, _token} ->
        updated_conn
        |> UserAuth.clear_unverified_user()
        |> put_flash(
          :success,
          dgettext("auth", "Your email has been successfully verified! You're now logged in.")
        )
        |> redirect(to: get_success_redirect_path())

      {:error, _reason, details} ->
        Logger.error("Failed to create session after verification", details: details)
        redirect_to_login_verified(conn)
    end
  end

  defp redirect_to_login_verified(conn) do
    conn
    |> put_flash(
      :info,
      dgettext("auth", "Your email has been successfully verified! Please log in to continue.")
    )
    |> redirect(to: ~p"/auth/login")
  end

  # Shown when a verification link's token is no longer in the database: most
  # commonly because a newer verification email was requested (each request
  # rotates the token), but also for already-used or malformed links.
  defp link_superseded_message do
    dgettext(
      "auth",
      "This verification link is no longer valid. If you've requested a newer verification email, please open the link in the most recent one."
    )
  end

  # Shown when the token is still on record but its 24-hour validity window lapsed.
  defp link_expired_message do
    dgettext(
      "auth",
      "This verification link has expired. Please request a new verification email to continue."
    )
  end

  defp get_success_redirect_path do
    Config.success_redirect_path()
  end
end
