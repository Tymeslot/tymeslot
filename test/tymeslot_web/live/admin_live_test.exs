defmodule TymeslotWeb.AdminLiveTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :live
  @moduletag :auth

  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import Tymeslot.AuthTestHelpers

  alias Tymeslot.AppSettings
  alias Tymeslot.Auth
  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Repo

  setup do
    # In the umbrella, the endpoint routes through SaaS by default
    # (apps/tymeslot_saas/config/runtime.exs). Point it at Core's router so
    # the admin scope is reachable for these tests — they cover Core
    # behaviour, not the SaaS lockdown which has its own coverage.
    original_router = Application.get_env(:tymeslot, :router)
    Application.put_env(:tymeslot, :router, TymeslotWeb.Router)
    Application.put_env(:tymeslot, :enable_admin_ui, true)
    Application.put_env(:tymeslot, :registration_enabled, true)

    on_exit(fn ->
      if original_router,
        do: Application.put_env(:tymeslot, :router, original_router),
        else: Application.delete_env(:tymeslot, :router)

      Application.put_env(:tymeslot, :enable_admin_ui, true)
      Application.put_env(:tymeslot, :registration_enabled, true)
    end)

    :ok
  end

  describe "access control" do
    test "authenticated non-admin is redirected to /dashboard with a flash", %{conn: conn} do
      user = insert(:user, is_admin: false)
      conn = log_in_user(conn, user)

      conn = get(conn, ~p"/admin")
      assert redirected_to(conn) == ~p"/dashboard"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Admin access required."
    end

    test "unauthenticated request redirected to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: redirect_to}}} = live(conn, ~p"/admin")
      assert redirect_to =~ "/auth/login"
    end

    test "admin user can mount /admin", %{conn: conn} do
      admin = insert(:user, is_admin: true)
      conn = log_in_user(conn, admin)

      {:ok, _lv, html} = live(conn, ~p"/admin")
      assert html =~ "Admin"
      assert html =~ "Total users"
    end

    test "returns 404 when enable_admin_ui is false", %{conn: conn} do
      Application.put_env(:tymeslot, :enable_admin_ui, false)
      admin = insert(:user, is_admin: true)
      conn = log_in_user(conn, admin)

      conn = get(conn, ~p"/admin")
      assert conn.status == 404
    end

    test "open socket is redirected to /dashboard after actor's admin status is revoked", %{
      conn: conn
    } do
      admin_a = insert(:user, is_admin: true)
      admin_b = insert(:user, is_admin: true)
      target = insert(:user, is_admin: false)
      conn = log_in_user(conn, admin_a)

      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      # Revoke admin_a's admin status via another admin (admin_b acting as the actor)
      {:ok, _demoted} = Auth.demote_admin(admin_b, admin_a.id)

      # Sending any event through the now-demoted socket must be halted and redirected
      assert {:error, {:live_redirect, %{to: redirect_to}}} =
               lv |> promote_button(target.id) |> render_click()

      assert redirect_to =~ "/dashboard"
    end
  end

  describe "settings tab" do
    setup %{conn: conn} do
      admin = insert(:user, is_admin: true)
      {:ok, conn: log_in_user(conn, admin), admin: admin}
    end

    test "toggling registration_enabled persists and takes effect immediately", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      lv
      |> form("#app-settings-form", %{"app_settings" => %{"registration_enabled" => "false"}})
      |> render_submit()

      assert Application.get_env(:tymeslot, :registration_enabled) == false
      assert %{registration_enabled: false} = AppSettings.get!()
    end

    test "reset returns the setting to the config/baseline value", %{conn: conn} do
      AppSettings.load!()
      {:ok, _settings} = AppSettings.update(%{registration_enabled: false})
      assert Application.get_env(:tymeslot, :registration_enabled) == false

      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      lv
      |> element("button[phx-value-key=registration_enabled]", "Reset")
      |> render_click()

      # The default fallback (Core ships with registration_enabled: true) is restored.
      assert Application.get_env(:tymeslot, :registration_enabled) == true
      assert %{registration_enabled: nil} = AppSettings.get!()
    end
  end

  describe "users tab" do
    setup %{conn: conn} do
      admin = insert(:user, is_admin: true)
      other_admin = insert(:user, is_admin: true)
      regular = insert(:user, is_admin: false)

      {:ok,
       conn: log_in_user(conn, admin), admin: admin, other_admin: other_admin, regular: regular}
    end

    test "promote sets is_admin to true", %{conn: conn, regular: regular} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      lv |> promote_button(regular.id) |> render_click()

      assert Repo.reload!(regular).is_admin
    end

    test "demote sets is_admin to false on another admin", %{conn: conn, other_admin: other_admin} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      lv |> demote_button(other_admin.id) |> render_click()

      refute Repo.reload!(other_admin).is_admin
    end

    test "demote refuses to demote the only remaining admin", %{conn: conn, admin: admin} do
      # Demote every admin except the current user, leaving them as the only
      # admin. The next demote of the current user (who is also the only
      # remaining admin) must be rejected.
      UserQueries.list_admins()
      |> Enum.reject(&(&1.id == admin.id))
      |> Enum.each(fn other -> UserQueries.set_admin(other, false) end)

      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      # Try to demote the current admin via the controller path. The "self"
      # guard fires first; either way the row must stay an admin.
      lv |> demote_button(admin.id) |> render_click()

      assert Repo.reload!(admin).is_admin
    end
  end

  defp promote_button(lv, id) do
    element(lv, ~s|button[phx-click="promote_user"][phx-value-id="#{id}"]|)
  end

  defp demote_button(lv, id) do
    element(lv, ~s|button[phx-click="demote_user"][phx-value-id="#{id}"]|)
  end
end
