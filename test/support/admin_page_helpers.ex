defmodule Tymeslot.AdminPageHelpers do
  @moduledoc """
  Shared `setup` for LiveView tests that drive the admin pages.

  Reaching `/admin/*` in a test needs three things arranged together: the
  endpoint pointed at Core's router, the admin UI switched on, and a signed-in
  admin. Under a downstream overlay the endpoint routes through that overlay's
  router by default, which 404s Core's admin scope — these tests cover Core
  behaviour, not an overlay's lockdown, which has its own coverage.

  Extracted so the admin test modules share one copy rather than each carrying
  the same block.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]
  import Tymeslot.AuthTestHelpers, only: [log_in_user: 2]
  import Tymeslot.Factory, only: [insert: 2]

  @doc """
  ExUnit `setup` callback returning a `conn` signed in as an admin, with the
  router and admin-UI flag restored afterwards. Use as
  `setup :admin_conn`.
  """
  @spec admin_conn(map()) :: {:ok, keyword()}
  def admin_conn(%{conn: conn}) do
    original_router = Application.get_env(:tymeslot, :router)
    Application.put_env(:tymeslot, :router, TymeslotWeb.Router)
    Application.put_env(:tymeslot, :enable_admin_ui, true)

    on_exit(fn ->
      if original_router,
        do: Application.put_env(:tymeslot, :router, original_router),
        else: Application.delete_env(:tymeslot, :router)

      Application.put_env(:tymeslot, :enable_admin_ui, true)
    end)

    admin = insert(:user, is_admin: true)

    {:ok, conn: log_in_user(conn, admin), admin: admin}
  end
end
