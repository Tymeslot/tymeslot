defmodule TymeslotWeb.CalendarOAuthController do
  @moduledoc """
  Handles OAuth callbacks for calendar integrations (Google and Outlook).
  """

  use TymeslotWeb, :controller

  alias TymeslotWeb.OAuthCallbackHandler

  @doc """
  Handles Google Calendar OAuth callback.
  """
  @spec google_callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def google_callback(conn, params),
    do: OAuthCallbackHandler.handle(conn, params, :google_calendar)

  @doc """
  Handles Outlook Calendar OAuth callback.
  """
  @spec outlook_callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def outlook_callback(conn, params),
    do: OAuthCallbackHandler.handle(conn, params, :outlook_calendar)
end
