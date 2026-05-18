defmodule TymeslotWeb.Plugs.RequireAdminUiEnabled do
  @moduledoc """
  Halts with a 404 (not a 403) when the admin UI is disabled for the current
  deployment. Returning 404 prevents the SaaS overlay from leaking the
  existence of admin routes that only the open-source Core ships with.
  """

  import Plug.Conn
  alias Phoenix.Controller

  @spec init(Keyword.t()) :: Keyword.t()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if Application.get_env(:tymeslot, :enable_admin_ui, true) do
      conn
    else
      conn
      |> put_status(:not_found)
      |> Controller.put_view(html: TymeslotWeb.ErrorHTML, json: TymeslotWeb.ErrorJSON)
      |> Controller.render(:"404")
      |> halt()
    end
  end
end
