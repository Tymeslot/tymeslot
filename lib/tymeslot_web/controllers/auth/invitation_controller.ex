defmodule TymeslotWeb.InvitationController do
  @moduledoc """
  The page an invited user reaches from their invitation email: they choose
  a password, which accepts the invitation and signs them in.

  Opening the link only renders the form; the token is spent by the POST, so
  a mail scanner prefetching the link cannot use it up.
  """

  use TymeslotWeb, :controller
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Auth.Invitations
  alias Tymeslot.Infrastructure.Config
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.InvitationHTML
  alias TymeslotWeb.UserAuth

  require Logger

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"token" => token}) do
    case Invitations.fetch(token) do
      {:ok, user} -> render_form(conn, token, user.email, nil)
      {:error, reason} -> refuse(conn, reason)
    end
  end

  @spec accept(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def accept(conn, %{"token" => token, "invitation" => params}) do
    password = Map.get(params, "password", "")
    confirmation = Map.get(params, "password_confirmation", "")

    case Invitations.accept(token, password, confirmation, ClientIP.request_opts(conn)) do
      {:ok, user} ->
        sign_in(conn, user)

      {:error, reason, message} when reason in [:invalid_input, :rate_limited] ->
        case Invitations.fetch(token) do
          {:ok, user} -> render_form(conn, token, user.email, message)
          {:error, fetch_reason} -> refuse(conn, fetch_reason)
        end

      {:error, reason} ->
        refuse(conn, reason)
    end
  end

  def accept(conn, %{"token" => token}),
    do: accept(conn, %{"token" => token, "invitation" => %{}})

  defp render_form(conn, token, email, error) do
    conn
    |> put_layout(html: false)
    |> put_view(html: InvitationHTML)
    |> render(:show,
      page_title: dgettext("auth", "Accept your invitation"),
      action: ~p"/auth/invitation/#{token}",
      email: email,
      error: error
    )
  end

  defp sign_in(conn, user) do
    case UserAuth.create_session(conn, user) do
      {:ok, conn, _token} ->
        conn
        |> put_flash(:success, dgettext("auth", "Welcome to Tymeslot! Your password is set."))
        |> redirect(to: Config.success_redirect_path())

      {:error, _reason, details} ->
        Logger.error("Failed to create session after accepting an invitation",
          user_id: user.id,
          details: details
        )

        conn
        |> put_flash(:info, dgettext("auth", "Your password is set. Please log in to continue."))
        |> redirect(to: ~p"/auth/login")
    end
  end

  defp refuse(conn, reason) do
    conn
    |> put_flash(:error, refusal_message(reason))
    |> redirect(to: ~p"/auth/login")
  end

  defp refusal_message(:token_expired),
    do:
      dgettext(
        "auth",
        "This invitation has expired. Ask your administrator to send you a new one."
      )

  defp refusal_message(:password_auth_disabled),
    do:
      dgettext(
        "auth",
        "Password sign-in is turned off, so this invitation can't be accepted. Please contact your administrator."
      )

  defp refusal_message(_invalid),
    do:
      dgettext(
        "auth",
        "This invitation link is no longer valid. It may have been used already, or replaced by a newer invitation."
      )
end
