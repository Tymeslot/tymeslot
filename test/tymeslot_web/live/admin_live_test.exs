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

    test "admin user can mount /admin and lands on the settings tab", %{conn: conn} do
      admin = insert(:user, is_admin: true)
      conn = log_in_user(conn, admin)

      {:ok, _lv, html} = live(conn, ~p"/admin")
      assert html =~ "Admin"
      assert html =~ "Environment / config"
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

    test "clicking the Disabled tag persists and takes effect immediately", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      html =
        lv
        |> setting_tag(:registration_enabled, "false")
        |> render_click()

      assert Application.get_env(:tymeslot, :registration_enabled) == false
      assert %{registration_enabled: false} = AppSettings.get!()
      assert html =~ "Registration enabled disabled."
    end

    test "clicking the Enabled tag persists and takes effect immediately", %{conn: conn} do
      AppSettings.load!()
      {:ok, _settings} = AppSettings.update(%{registration_enabled: false})

      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      html =
        lv
        |> setting_tag(:registration_enabled, "true")
        |> render_click()

      assert Application.get_env(:tymeslot, :registration_enabled) == true
      assert %{registration_enabled: true} = AppSettings.get!()
      assert html =~ "Registration enabled enabled."
    end

    test "the tag matching the effective value is disabled so re-clicks are no-ops", %{conn: conn} do
      AppSettings.load!()
      {:ok, _settings} = AppSettings.update(%{registration_enabled: false})

      {:ok, _lv, html} = live(conn, ~p"/admin/settings")

      # The Disabled tag is active because the effective value is false.
      assert html =~
               ~s(phx-value-key="registration_enabled" phx-value-state="false" disabled)
    end

    test "each setting row shows a description with a recommended value", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/settings")

      assert html =~ "Allow new users to sign up"
      assert html =~ "Allow log-in with email and password"
      assert html =~ "Recommended: Enabled"
    end

    test "shows an info banner explaining the env-var override behaviour", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/settings")

      assert html =~ "override the matching environment variables"
      assert html =~ "REGISTRATION_ENABLED"
      assert html =~ "PASSWORD_AUTH_ENABLED"
    end

    test "toggling registration off via the LiveView blocks public sign-ups", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      lv |> setting_tag(:registration_enabled, "false") |> render_click()

      # End-to-end: an admin's click in the UI propagates through to the
      # public registration entry point.
      assert {:error, :registration_disabled, _msg} =
               Auth.register_user(%{"email" => "new@example.com"}, %Plug.Conn{})

      lv |> setting_tag(:registration_enabled, "true") |> render_click()

      refute match?(
               {:error, :registration_disabled, _ignored},
               Auth.register_user(%{"email" => "new@example.com"}, %Plug.Conn{})
             )
    end

    test "refuses to disable password auth when no OAuth provider is configured", %{conn: conn} do
      original_social = Application.get_env(:tymeslot, :social_auth, [])
      original_password_auth = Application.get_env(:tymeslot, :password_auth_enabled)

      Application.put_env(:tymeslot, :social_auth,
        google_enabled: false,
        github_enabled: false,
        oauth_enabled: false
      )

      on_exit(fn ->
        Application.put_env(:tymeslot, :social_auth, original_social)

        if original_password_auth == nil do
          Application.delete_env(:tymeslot, :password_auth_enabled)
        else
          Application.put_env(:tymeslot, :password_auth_enabled, original_password_auth)
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      html =
        lv
        |> setting_tag(:password_auth_enabled, "false")
        |> render_click()

      assert html =~ "would lock every user out"
      # The setting did not actually change.
      assert Application.get_env(:tymeslot, :password_auth_enabled) == true
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

    test "users tab shows total-user and admin counts at the top", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/users")

      assert html =~ "Total users"
      assert html =~ "Admins"
    end

    test "promote sets is_admin to true", %{conn: conn, regular: regular} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      lv |> promote_button(regular.id) |> render_click()
      lv |> confirm_promote() |> render_click()

      assert Repo.reload!(regular).is_admin
    end

    test "promote confirmation modal opens with the target's email", %{
      conn: conn,
      regular: regular
    } do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      html = lv |> promote_button(regular.id) |> render_click()

      assert html =~ "Promote user to admin"
      assert html =~ regular.email
    end

    test "cancelling the modal does not change admin status", %{conn: conn, regular: regular} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      lv |> promote_button(regular.id) |> render_click()
      render_hook(lv, "cancel_pending_action", %{})

      refute Repo.reload!(regular).is_admin
    end

    test "demote sets is_admin to false on another admin", %{conn: conn, other_admin: other_admin} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      lv |> demote_button(other_admin.id) |> render_click()
      lv |> confirm_demote() |> render_click()

      refute Repo.reload!(other_admin).is_admin
    end

    test "demote button is replaced by a note when the actor is the only admin",
         %{conn: conn, admin: admin} do
      # Demote every admin except the current user, leaving them as the only
      # admin. The UI must offer no way to demote — instead an inline note
      # explains why.
      UserQueries.list_admins()
      |> Enum.reject(&(&1.id == admin.id))
      |> Enum.each(fn other -> UserQueries.set_admin(other, false) end)

      {:ok, lv, html} = live(conn, ~p"/admin/users")

      # No active demote button for the self row.
      refute has_element?(lv, ~s|button[phx-click="request_demote"][phx-value-id="#{admin.id}"]|)

      # The inline note is visible.
      assert html =~ "last-admin-self-note"
      assert html =~ "You&#39;re the only admin"

      # And the user remains an admin.
      assert Repo.reload!(admin).is_admin
    end

    test "admin can demote themselves when another admin exists; redirects to /dashboard",
         %{conn: conn, admin: admin, other_admin: other_admin} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      # The self-row's demote button IS clickable because another admin remains.
      assert has_element?(lv, ~s|button[phx-click="request_demote"][phx-value-id="#{admin.id}"]|)

      lv |> demote_button(admin.id) |> render_click()

      # Modal copy uses the self-aware variant.
      assert render(lv) =~ "Demote yourself"

      # Confirming triggers a redirect (full reload) to /dashboard.
      assert {:error, {:redirect, %{to: redirect_to}}} =
               lv |> confirm_demote() |> render_click()

      assert redirect_to == ~p"/dashboard"

      # Self is now demoted; other_admin still has admin rights.
      refute Repo.reload!(admin).is_admin
      assert Repo.reload!(other_admin).is_admin
    end

    test "after self-demote, /admin redirects to /dashboard with a flash",
         %{conn: conn, admin: admin} do
      # Simulate the post-demote state: user is no longer admin.
      {:ok, _user} = UserQueries.set_admin(admin, false)

      conn = get(conn, ~p"/admin")

      assert redirected_to(conn) == ~p"/dashboard"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Admin access required."
    end

    test "after self-demote, the dashboard dropdown no longer shows Admin Settings",
         %{conn: conn, admin: admin} do
      # The dashboard requires onboarding to be complete before it renders.
      {:ok, admin} =
        admin
        |> Ecto.Changeset.change(
          onboarding_completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )
        |> Repo.update()

      {:ok, _user} = UserQueries.set_admin(admin, false)

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ "Admin Settings"
    end
  end

  defp promote_button(lv, id) do
    element(lv, ~s|button[phx-click="request_promote"][phx-value-id="#{id}"]|)
  end

  defp demote_button(lv, id) do
    element(lv, ~s|button[phx-click="request_demote"][phx-value-id="#{id}"]|)
  end

  defp confirm_promote(lv) do
    element(lv, ~s|#confirm-role-change-modal button[phx-click="promote_user"]|)
  end

  defp confirm_demote(lv) do
    element(lv, ~s|#confirm-role-change-modal button[phx-click="demote_user"]|)
  end

  defp setting_tag(lv, key, state) do
    element(
      lv,
      ~s|button[phx-click="set_setting"][phx-value-key="#{key}"][phx-value-state="#{state}"]|
    )
  end
end
