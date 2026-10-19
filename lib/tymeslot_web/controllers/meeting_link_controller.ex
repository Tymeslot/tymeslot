defmodule TymeslotWeb.MeetingLinkController do
  @moduledoc """
  Resolves a booking's cancel or reschedule link that carries no username
  (`/meeting/:meeting_uid/cancel`) to the host's current page for it.

  The meeting uid is what authorises those pages, so redirecting on it alone
  grants nothing the link did not. An unknown uid, or a host who still has no
  username, is a 404.
  """

  use TymeslotWeb, :controller

  alias Tymeslot.Bookings.MeetingLinks

  @spec cancel(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cancel(conn, %{"meeting_uid" => uid}), do: redirect_to_current(conn, uid, :cancel)

  @spec reschedule(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reschedule(conn, %{"meeting_uid" => uid}), do: redirect_to_current(conn, uid, :reschedule)

  defp redirect_to_current(conn, uid, page) do
    case MeetingLinks.current_path(uid, page) do
      {:ok, path} ->
        redirect(conn, to: path)

      {:error, :not_found} ->
        raise TymeslotWeb.NotFoundError, "No meeting page for this link"
    end
  end
end
