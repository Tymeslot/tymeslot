defmodule TymeslotWeb.Plugs.EnsureMainDeploymentPlug do
  @moduledoc """
  Plug to ensure certain routes are only accessible on the main deployment.
  Redirects to login page for self-hosted deployments.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Tymeslot.Deployment

  @spec init(Keyword.t()) :: Keyword.t()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if Deployment.main?() do
      conn
    else
      conn
      |> redirect(to: "/auth/login")
      |> halt()
    end
  end
end
