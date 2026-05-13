defmodule TymeslotWeb.Plugs.RequireAdmin do
  @moduledoc """
  Halts the request with a 404 when `conn.assigns.current_user` is missing or
  not an admin. Returning 404 (rather than 403) keeps the existence of the
  admin scope opaque to non-admins.
  """

  import Plug.Conn
  alias Phoenix.Controller
  alias Tymeslot.Auth.UserSchema

  @spec init(Keyword.t()) :: Keyword.t()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
  def call(%Plug.Conn{assigns: %{current_user: %UserSchema{is_admin: true}}} = conn, _opts) do
    conn
  end

  def call(conn, _opts) do
    conn
    |> put_status(:not_found)
    |> Controller.put_view(html: TymeslotWeb.ErrorHTML, json: TymeslotWeb.ErrorJSON)
    |> Controller.render(:"404")
    |> halt()
  end
end
