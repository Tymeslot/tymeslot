defmodule TymeslotWeb.Plugs.EnsureLocalAccessPlug do
  @moduledoc """
  Plug to ensure that only local requests can access certain routes.
  Useful for debug routes and development-only endpoints.

  ## Usage

      pipeline :local_only do
        plug TymeslotWeb.Plugs.EnsureLocalAccessPlug
      end

      scope "/debug" do
        pipe_through [:browser, :local_only]
        # debug routes here
      end

  ## Options

    * `:error_view` - The error view module to use (defaults to TymeslotWeb.ErrorHTML)
    * `:error_template` - The error template to render (defaults to :"403")
    * `:allow_docker` - Allow Docker internal networks (defaults to false)
  """

  import Plug.Conn
  import Phoenix.Controller

  @spec init(Keyword.t()) :: Keyword.t()
  def init(options) do
    options
    |> Keyword.put_new(:error_view, TymeslotWeb.ErrorHTML)
    |> Keyword.put_new(:error_template, :"403")
    |> Keyword.put_new(:allow_docker, false)
  end

  @spec call(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
  def call(conn, opts) do
    if local_request?(conn, opts) do
      conn
    else
      error_view = Keyword.get(opts, :error_view)
      error_template = Keyword.get(opts, :error_template)

      conn
      |> put_status(:forbidden)
      |> put_view(error_view)
      |> render(error_template)
      |> halt()
    end
  end

  @spec local_request?(Plug.Conn.t(), Keyword.t()) :: boolean()
  defp local_request?(conn, opts) do
    allow_docker = Keyword.get(opts, :allow_docker, false)

    case conn.remote_ip do
      # IPv4 localhost
      {127, 0, 0, 1} -> true
      # IPv6 localhost
      {0, 0, 0, 0, 0, 0, 0, 1} -> true
      # Docker internal networks (if enabled)
      {172, second, _, _} when allow_docker and second >= 16 and second <= 31 -> true
      {10, _, _, _} when allow_docker -> true
      {192, 168, _, _} when allow_docker -> true
      _ -> false
    end
  end
end
