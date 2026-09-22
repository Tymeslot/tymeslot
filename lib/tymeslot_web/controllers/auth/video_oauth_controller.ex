defmodule TymeslotWeb.VideoOAuthController do
  @moduledoc """
  Handles OAuth callbacks for video integrations (Google Meet, Microsoft Teams, Zoom).
  """

  use TymeslotWeb, :controller

  alias TymeslotWeb.OAuthCallbackHandler

  @doc """
  Handles Google Meet OAuth callback.
  """
  @spec google_callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def google_callback(conn, params), do: OAuthCallbackHandler.handle(conn, params, :google_meet)

  @doc """
  Handles Microsoft Teams OAuth callback.
  """
  @spec teams_callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def teams_callback(conn, params), do: OAuthCallbackHandler.handle(conn, params, :teams)

  @doc """
  Handles Zoom OAuth callback.
  """
  @spec zoom_callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def zoom_callback(conn, params), do: OAuthCallbackHandler.handle(conn, params, :zoom)
end
