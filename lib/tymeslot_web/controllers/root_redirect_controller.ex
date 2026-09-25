defmodule TymeslotWeb.RootRedirectController do
  @moduledoc """
  Handles the root path routing for self-hosted deployments.

    * Redirects authenticated users to the dashboard.
    * Redirects unauthenticated users to the login page.
  """
  use TymeslotWeb, :controller

  @doc "Redirects `/` to the dashboard or the login page."
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    if conn.assigns[:current_user] do
      redirect(conn, to: ~p"/dashboard")
    else
      redirect(conn, to: ~p"/auth/login")
    end
  end
end
