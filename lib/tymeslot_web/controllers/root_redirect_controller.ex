defmodule TymeslotWeb.RootRedirectController do
  use TymeslotWeb, :controller

  alias Tymeslot.Deployment

  @doc """
  Handles the root path routing based on deployment type and authentication status.
  - Main deployment: Redirects to homepage LiveView for unauthenticated users
  - Self-hosted deployments: Redirects to login for unauthenticated users
  - All deployments: Redirects authenticated users to dashboard
  """
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    if conn.assigns[:current_user] do
      # User is logged in, redirect to dashboard
      redirect(conn, to: ~p"/dashboard")
    else
      # User is not logged in, check deployment type
      if Deployment.main?() do
        # Main deployment: render homepage LiveView
        conn
        |> Phoenix.Controller.put_root_layout(html: {TymeslotWeb.Layouts, :root})
        |> Phoenix.Controller.put_layout(html: {TymeslotWeb.Layouts, :app})
        |> Phoenix.LiveView.Controller.live_render(TymeslotWeb.HomepageLive, session: %{})
      else
        # Self-hosted deployment: redirect to login
        redirect(conn, to: ~p"/auth/login")
      end
    end
  end
end
