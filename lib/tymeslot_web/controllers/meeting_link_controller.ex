defmodule TymeslotWeb.MeetingLinkController do
  @moduledoc """
  Resolves a booking's cancel or reschedule link that carries no username
  (`/meeting/:meeting_uid/cancel`), or a series page link without one
  (`/series/:series_uid`), to the host's current page for it.

  The meeting or series uid is what authorises those pages, so redirecting
  on it alone grants nothing the link did not. An unknown uid, or a host who still has no
  username, is a 404.
  """

  use TymeslotWeb, :controller

  alias Tymeslot.Bookings.MeetingLinks

  @spec cancel(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cancel(conn, %{"meeting_uid" => uid}), do: redirect_to_current(conn, uid, :cancel)

  @spec reschedule(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reschedule(conn, %{"meeting_uid" => uid}), do: redirect_to_current(conn, uid, :reschedule)

  @spec series(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def series(conn, %{"series_uid" => uid}),
    do: redirect_or_not_found(conn, MeetingLinks.current_series_path(uid))

  defp redirect_to_current(conn, uid, page),
    do: redirect_or_not_found(conn, MeetingLinks.current_path(uid, page))

  defp redirect_or_not_found(conn, current_path) do
    case current_path do
      {:ok, path} ->
        redirect(conn, to: path)

      {:error, :not_found} ->
        raise TymeslotWeb.NotFoundError, "No page for this link"
    end
  end
end
