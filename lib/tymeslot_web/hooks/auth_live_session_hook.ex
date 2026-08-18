defmodule TymeslotWeb.Hooks.AuthLiveSessionHook do
  @moduledoc """
  LiveView hook for handling authentication in LiveView sessions.

  This module provides on_mount hooks for LiveView to:
  1. Check authentication status
  2. Halt and redirect unauthorized users
  3. Assign the current user to the socket

  ## Usage

  In your router.ex:

  ```elixir
  live_session :authenticated, on_mount: {TymeslotWeb.Hooks.AuthLiveSessionHook, :ensure_authenticated} do
    scope "/app", YourAppWeb do
      pipe_through [:browser, :authenticated_live]

      live "/dashboard", DashboardLive
    end
  end
  ```
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.LiveView
  import Phoenix.Component

  alias Tymeslot.Auth.Authentication

  @doc """
  Handle the on_mount callback for the given hook.

  Different hooks provide different authentication behaviors:
  - :ensure_authenticated - Ensures the user is logged in
  - :fetch_current_user - Gets the current user without requiring authentication
  - :ensure_not_authenticated - Ensures the user is NOT logged in (useful for login pages)
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont | :halt, Phoenix.LiveView.Socket.t()}
  def on_mount(hook, _params, session, socket)

  def on_mount(:ensure_authenticated, _params, session, socket) do
    case session["user_token"] do
      nil ->
        redirect_path = login_path()

        socket =
          socket
          |> put_flash(:error, dgettext("auth", "You must be logged in to access this page."))
          |> redirect(to: redirect_path)

        {:halt, socket}

      token ->
        user = Authentication.get_user_by_session_token(token)

        if user do
          # Add convenience assign for email verification status
          is_email_verified = user.verified_at != nil

          socket =
            socket
            |> assign(:current_user, user)
            |> assign(:is_email_verified, is_email_verified)

          {:cont, socket}
        else
          redirect_path = login_path()

          socket =
            socket
            |> put_flash(
              :error,
              dgettext("auth", "Your session has expired. Please log in again.")
            )
            |> redirect(to: redirect_path)

          {:halt, socket}
        end
    end
  end

  def on_mount(:fetch_current_user, _params, session, socket) do
    case session["user_token"] do
      nil ->
        {:cont, assign(socket, :current_user, nil)}

      token ->
        user = Authentication.get_user_by_session_token(token)
        # Add convenience assign for email verification status
        is_email_verified = if user, do: user.verified_at != nil, else: false

        socket =
          socket
          |> assign(:current_user, user)
          |> assign(:is_email_verified, is_email_verified)

        {:cont, socket}
    end
  end

  def on_mount(:ensure_not_authenticated, _params, session, socket) do
    case session["user_token"] do
      nil ->
        {:cont, assign(socket, :current_user, nil)}

      token ->
        user = Authentication.get_user_by_session_token(token)

        if user do
          redirect_path = auth_config(:success_redirect_path, "/dashboard")

          socket =
            socket
            |> put_flash(:info, dgettext("auth", "You are already logged in."))
            |> redirect(to: redirect_path)

          {:halt, socket}
        else
          {:cont, assign(socket, :current_user, nil)}
        end
    end
  end

  # The login path lived under OTP app `:auth`, which neither repo configures,
  # so the inline default always won. It belongs in the same `:tymeslot, :auth`
  # keyword list the post-login redirect already reads.
  defp login_path, do: auth_config(:login_path, "/auth/login")

  defp auth_config(key, default) do
    :tymeslot
    |> Application.get_env(:auth, [])
    |> Keyword.get(key, default)
  end
end
