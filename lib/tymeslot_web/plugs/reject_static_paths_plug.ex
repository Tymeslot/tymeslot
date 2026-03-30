defmodule TymeslotWeb.Plugs.RejectStaticPathsPlug do
  @moduledoc """
  Returns 404 for requests whose first path segment looks like a static asset.

  Digested filenames (e.g. `embed-<hash>.js`) can slip past `Plug.Static`
  when the compiled asset doesn't exist on disk (dev worktrees, CI). Without
  this plug they fall through to the `/:username` LiveView catch-all and
  produce a misleading 302 redirect to the homepage.
  """

  @behaviour Plug

  import Plug.Conn

  @static_extensions ~w(.js .css .map .json .ico .png .jpg .svg .woff .woff2 .ttf .gz)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%{halted: true} = conn, _opts), do: conn

  def call(%{path_info: [segment | _rest]} = conn, _opts) do
    if Enum.any?(@static_extensions, &String.ends_with?(segment, &1)) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Not Found")
      |> halt()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn
end
