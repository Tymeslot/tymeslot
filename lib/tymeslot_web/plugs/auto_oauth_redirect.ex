defmodule TymeslotWeb.Plugs.AutoOAuthRedirect do
  @moduledoc """
  Starts generic OAuth from the login page when it is the only way in.

  Runs after `ReturnTo`, so a guarded page is already in the session before
  the OAuth round trip. Signed-out, error, and flash-bearing landings stay on
  the login page rather than starting another flow.
  """

  @behaviour Plug

  import Plug.Conn, only: [halt: 1]

  alias Phoenix.Controller
  alias Tymeslot.Auth.OAuth.Providers
  alias Tymeslot.Infrastructure.Config

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "GET", request_path: "/auth/login"} = conn, _opts) do
    if is_nil(conn.assigns[:current_user]) and sso_only?() and ordinary_entry?(conn) do
      conn
      |> Controller.redirect(to: "/auth/oauth")
      |> halt()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  defp sso_only? do
    not Config.password_auth_enabled?() and match?([%{slug: "oauth"}], Providers.enabled())
  end

  defp ordinary_entry?(conn) do
    params = conn.query_params

    not Map.has_key?(params, "signed_out") and not Map.has_key?(params, "error") and
      (Map.has_key?(params, "redirect_to") or Enum.empty?(conn.assigns[:flash] || %{}))
  end
end
