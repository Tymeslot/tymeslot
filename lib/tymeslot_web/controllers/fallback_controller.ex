defmodule TymeslotWeb.FallbackController do
  use TymeslotWeb, :controller
  alias Tymeslot.Demo

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"path" => [username | _rest]} = _params) do
    # Try to resolve username to see if we should fallback to profile or homepage
    case Demo.resolve_organizer_context(username) do
      {:ok, _context} ->
        conn
        |> put_flash(:error, "Page not found. Redirected to profile.")
        |> redirect(to: "/#{username}")

      _error ->
        conn
        |> put_flash(:error, "Page not found.")
        |> redirect(to: "/")
    end
  end

  def index(conn, _params) do
    conn
    |> put_flash(:error, "Page not found.")
    |> redirect(to: "/")
  end
end
