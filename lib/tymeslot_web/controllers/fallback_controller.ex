defmodule TymeslotWeb.FallbackController do
  use TymeslotWeb, :controller
  alias Tymeslot.Demo

  # Static asset extensions that should never be treated as usernames.
  # Catches digested filenames (e.g. embed-<hash>.js) that slip past Plug.Static
  # when the compiled asset doesn't exist on disk (dev, CI, worktrees).
  @static_extensions ~w(.js .css .map .json .ico .png .jpg .svg .woff .woff2 .ttf .gz)

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"path" => [segment | _rest]} = _params) do
    if Enum.any?(@static_extensions, &String.ends_with?(segment, &1)) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Not Found")
    else
      # Try to resolve username to see if we should fallback to profile or homepage
      case Demo.resolve_organizer_context(segment) do
        {:ok, _context} ->
          conn
          |> put_flash(:error, "Page not found. Redirected to profile.")
          |> redirect(to: ~p"/#{segment}")

        _error ->
          conn
          |> put_flash(:error, "Page not found.")
          |> redirect(to: ~p"/")
      end
    end
  end

  def index(conn, _params) do
    conn
    |> put_flash(:error, "Page not found.")
    |> redirect(to: ~p"/")
  end
end
