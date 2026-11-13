defmodule TymeslotWeb.BookingInvitationController do
  @moduledoc """
  The personal link a host shares for an invitation-only meeting type,
  `/invite/:token`.

  A link that can still book goes on to the type's own address carrying the
  token as `?invite=`, which the booking page's entry gate checks again. A
  used, expired or revoked one goes to the host's page saying why
  (`TymeslotWeb.Live.Scheduling.InvitationMessages`); a token that names no
  link, or a type no longer taking invitations, is a 404.

  The token is a credential, so every redirect is marked `no-store` and
  `no-referrer`: it is neither cached nor handed on in a referrer. The 404 is
  rendered by the error pipeline, which sets neither header, and carries no
  token.

  Every request counts against the client's `:booking_invitation` limit
  before the token is looked at; past it the answer is the error pipeline's
  plain-text `429 Too Many Requests`, which names no token.
  """

  use TymeslotWeb, :controller

  alias Tymeslot.BookingPages
  alias Tymeslot.Invitations
  alias Tymeslot.Profiles
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.ErrorHTML
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Live.Scheduling.InvitationMessages

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"token" => token}) do
    case RateLimiter.check(:booking_invitation, ClientIP.get(conn)) do
      :ok -> follow(conn, token)
      {:error, :rate_limited, _message} -> too_many_requests(conn)
    end
  end

  defp follow(conn, token) do
    case Invitations.resolve(token) do
      {:ok, invitation} ->
        path =
          BookingPages.meeting_type_path(
            host_profile!(invitation.user_id),
            invitation.meeting_type
          )

        conn
        |> private_response()
        |> redirect(to: path <> "?invite=" <> URI.encode_www_form(token))

      {:error, :not_found} ->
        not_found!()

      {:error, reason} ->
        profile = token |> Invitations.host_user_id() |> host_profile!()

        conn
        |> private_response()
        |> put_flash(:error, InvitationMessages.message(reason))
        |> redirect(to: "/" <> profile.username)
    end
  end

  # The error pipeline's plain answer, without the page layout, whose
  # canonical link would name the request's path and so the token.
  defp too_many_requests(conn) do
    conn
    |> private_response()
    |> put_resp_content_type("text/plain")
    |> send_resp(:too_many_requests, ErrorHTML.render("429.html", %{}))
  end

  defp private_response(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  # A host without a username has no booking page to send anyone to.
  defp host_profile!(user_id) when is_integer(user_id) do
    case Profiles.get_profile(user_id) do
      %{username: username} = profile when is_binary(username) -> profile
      _no_page -> not_found!()
    end
  end

  defp host_profile!(nil), do: not_found!()

  @spec not_found!() :: no_return()
  defp not_found!, do: raise(TymeslotWeb.NotFoundError, "No invitation for this link")
end
