defmodule TymeslotWeb.Plugs.ReturnTo do
  @moduledoc """
  Carries the page a signed-out visitor asked for through sign-in, so a host
  who follows a link to one booking lands on that booking afterwards.

  A guarded page sends the visitor to `login_path/1`, which names the page in
  `?redirect_to=`. This plug, on the sign-in routes, keeps it in the session
  when `Tymeslot.Security.RedirectPath.safe?/1` accepts it; every sign-in then
  ends on `pop/1`'s path rather than the dashboard home. The session is what
  carries it, not the URL, because two of the ways in finish on a later
  request than the one that brought the page: the OAuth provider's callback,
  and the emailed verification link that signs a new account in.

  Taking the path also removes it, so a later sign-in on the same browser
  cannot jump to a page asked for long ago, and one kept but never used
  expires after an hour. A plain visit to the login page
  leaves it alone, so a failed attempt that comes back there keeps it.

  A page longer than 2048 bytes is not kept: the session is a cookie,
  and one that outgrows the cookie's limit fails the whole response.
  """

  import Plug.Conn

  alias Tymeslot.Security.RedirectPath

  @behaviour Plug

  @param "redirect_to"
  @session_key "return_to"
  @max_age_seconds 3600
  @max_path_bytes 2048

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "GET"} = conn, _opts) do
    conn = fetch_query_params(conn)

    case conn.query_params[@param] do
      nil ->
        conn

      path ->
        if keepable?(path),
          do: put_session(conn, @session_key, %{"path" => path, "at" => now()}),
          else: conn
    end
  end

  def call(conn, _opts), do: conn

  @doc """
  The login page `login`, naming `path` as the page to return to when it is
  safe to.
  """
  @spec login_path(String.t() | nil, String.t()) :: String.t()
  def login_path(path, login \\ "/auth/login") do
    if keepable?(path),
      do:
        login
        |> URI.parse()
        |> URI.append_query(URI.encode_query(%{@param => path}))
        |> URI.to_string(),
      else: login
  end

  @doc "The path and query `conn` asked for, as `login_path/1` takes it."
  @spec requested_path(Plug.Conn.t()) :: String.t()
  def requested_path(%Plug.Conn{request_path: path, query_string: ""}), do: path

  def requested_path(%Plug.Conn{request_path: path, query_string: query}),
    do: path <> "?" <> query

  @doc """
  Takes the kept page out of the session: `{path, conn}` while it is fresh,
  `{nil, conn}` otherwise. The key is removed either way.
  """
  @spec pop(Plug.Conn.t()) :: {String.t() | nil, Plug.Conn.t()}
  def pop(conn) do
    path =
      case get_session(conn, @session_key) do
        %{"path" => path, "at" => at} when is_integer(at) ->
          if now() - at <= @max_age_seconds and keepable?(path), do: path

        _none ->
          nil
      end

    {path, delete_session(conn, @session_key)}
  end

  defp keepable?(path),
    do: is_binary(path) and byte_size(path) <= @max_path_bytes and RedirectPath.safe?(path)

  defp now, do: System.system_time(:second)
end
