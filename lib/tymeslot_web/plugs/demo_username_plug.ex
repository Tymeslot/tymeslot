defmodule TymeslotWeb.Plugs.DemoUsernamePlug do
  @moduledoc """
  Plug to restrict demo username routes to main deployment only.
  Redirects demo username requests to login page on self-hosted deployments.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Tymeslot.Deployment
  alias Tymeslot.TemplateDemo.Context

  @spec init(Keyword.t()) :: Keyword.t()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
  def call(conn, _opts) do
    username = conn.params["username"]

    if Context.demo_username?(username) and not Deployment.main?() do
      conn
      |> redirect(to: "/auth/login")
      |> halt()
    else
      conn
    end
  end
end
