defmodule TymeslotWeb.AuthAliasController do
  use TymeslotWeb, :controller

  @moduledoc """
  Convenience redirects from commonly mistyped auth slugs to their canonical
  `/auth/*` routes. Without these, `/login`, `/signup`, etc. fall through to the
  `/:username` booking-page catch-all and 404. Every slug routed here is also
  listed in `Tymeslot.Profiles.ReservedPaths`, so it can never shadow a real
  username — keep the two in sync when adding a new alias.
  """

  @spec login(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def login(conn, _params), do: redirect(conn, to: ~p"/auth/login")

  @spec signup(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def signup(conn, _params), do: redirect(conn, to: ~p"/auth/signup")
end
