defmodule TymeslotWeb.InvitationController do
  @moduledoc """
  The page an invited user reaches from their invitation email: they choose
  how they will sign in, with a password or an enabled social sign-in
  provider, which accepts the invitation and signs them in.

  Opening the link only renders the page; the token is spent by the password
  form's POST or by the provider's callback, so a mail scanner prefetching
  the link cannot use it up. A social acceptance finishes in
  `TymeslotWeb.OAuthController`, whose callback URL is the one registered
  with the provider.
  """

  use TymeslotWeb, :controller
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.Flash
  alias Tymeslot.Auth
  alias Tymeslot.Auth.Invitations
  alias Tymeslot.Auth.OAuth.Providers
  alias Tymeslot.Infrastructure.Config
  alias TymeslotWeb.AuthControllerHelpers
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.InvitationHTML
  alias TymeslotWeb.OAuthFlow
  alias TymeslotWeb.UserAuth

  require Logger

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"token" => token}) do
    case Invitations.fetch(token) do
      {:ok, user} -> render_page(conn, token, user.email, Flash.get(conn.assigns.flash, :error))
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
          {:ok, user} -> render_page(conn, token, user.email, message)
          {:error, fetch_reason} -> refuse(conn, fetch_reason)
        end

      {:error, reason} ->
        refuse(conn, reason)
    end
  end

  def accept(conn, %{"token" => token}),
    do: accept(conn, %{"token" => token, "invitation" => %{}})

  @doc """
  Starts accepting the invitation with a social sign-in: checks the link and
  the provider, then sends the invitee to the provider. Nothing is spent
  until the provider's callback.
  """
  @spec social(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def social(conn, %{"token" => token, "provider" => slug}) do
    with {:ok, provider} <- enabled_provider(slug),
         {:ok, _user} <- Invitations.fetch(token),
         :ok <- Auth.check_social_rate_limit(:initiation, ClientIP.request_opts(conn)) do
      {conn, authorize_url} = OAuthFlow.authorize_invitation(conn, provider, token)
      redirect(conn, external: authorize_url)
    else
      {:error, :provider_unavailable} ->
        conn
        |> put_flash(:error, dgettext("auth_invitation", "This sign-in option is not available."))
        |> redirect(to: ~p"/auth/invitation/#{token}")

      {:error, :rate_limited, _message} ->
        AuthControllerHelpers.handle_rate_limited(
          conn,
          dgettext("auth_invitation", "Too many OAuth attempts. Please try again later."),
          ~p"/auth/invitation/#{token}"
        )

      {:error, reason} ->
        refuse(conn, reason)
    end
  end

  defp enabled_provider(slug) do
    with {:ok, provider} <- Providers.parse(slug),
         true <- Providers.enabled?(provider) do
      {:ok, provider}
    else
      _unknown_or_disabled -> {:error, :provider_unavailable}
    end
  end

  defp render_page(conn, token, email, error) do
    conn
    |> put_layout(html: false)
    |> put_view(html: InvitationHTML)
    |> render(:show,
      page_title: dgettext("auth_invitation", "Accept your invitation"),
      action: ~p"/auth/invitation/#{token}",
      social_path: "/auth/invitation/#{token}",
      password_enabled: Config.password_auth_enabled?(),
      email: email,
      error: error
    )
  end

  defp sign_in(conn, user) do
    case UserAuth.create_session(conn, user) do
      {:ok, conn, _token} ->
        conn
        |> put_flash(
          :success,
          dgettext("auth_invitation", "Welcome to Tymeslot! Your password is set.")
        )
        |> redirect(to: Config.success_redirect_path())

      {:error, _reason, details} ->
        Logger.error("Failed to create session after accepting an invitation",
          user_id: user.id,
          details: details
        )

        conn
        |> put_flash(
          :info,
          dgettext("auth_invitation", "Your password is set. Please log in to continue.")
        )
        |> redirect(to: ~p"/auth/login")
    end
  end

  defp refuse(conn, reason) do
    conn
    |> put_flash(:error, InvitationHTML.refusal_message(reason))
    |> redirect(to: ~p"/auth/login")
  end
end
