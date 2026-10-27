defmodule TymeslotWeb.Plugs.RejectMalformedPathPlug do
  @moduledoc """
  Answers `400 Bad Request` for a path whose segments do not percent-decode to
  valid UTF-8 (`/%c0`), or decode to a NUL byte (`/%00`), which is valid UTF-8
  but which PostgreSQL refuses in text all the same.

  Plug rejects invalid UTF-8 in a query string, but nothing checks the path:
  the router decodes each segment and hands the result on as a path param.
  An invalid byte sequence then reaches a query (`/:username` looks the host
  up by it), and PostgreSQL refuses it with a `Postgrex.Error` that is tracked
  and alerted on as a server fault. It is scanner noise, so it stops here,
  before the router, for every route that takes a path param.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: segments} = conn, _opts) do
    if Enum.all?(segments, &(&1 |> URI.decode() |> storable?())) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(400, "Bad Request")
      |> halt()
    end
  end

  defp storable?(segment), do: String.valid?(segment) and not String.contains?(segment, <<0>>)
end
