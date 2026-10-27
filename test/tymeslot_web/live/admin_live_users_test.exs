defmodule TymeslotWeb.AdminLiveUsersTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :live
  @moduletag :auth

  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import Tymeslot.AdminPageHelpers

  alias Ecto.Changeset
  alias Phoenix.Flash
  alias Tymeslot.Auth.AdminUserQueries
  alias Tymeslot.Repo

  setup :admin_conn

  describe "users tab" do
    setup do
      {:ok, other_admin: insert(:user, is_admin: true), regular: insert(:user, is_admin: false)}
    end

    test "users tab shows total-user and admin counts at the top", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/users")

      # Each count must sit in the card carrying its own label; the admin
      # session, the other admin and the regular user make 3 and 2.
      assert stat_cards(html) == [{"Total users", "3"}, {"Admins", "2"}]
    end

    test "users tab lists each user's display name and booking slug", %{conn: conn} do
      user = insert(:user, is_admin: false)

      insert(:profile,
        user: user,
        full_name: "Ada Lovelace",
        username: "ada-lovelace"
      )

      {:ok, _lv, html} = live(conn, ~p"/admin/users")

      assert html =~ "Display name"
      assert html =~ "Booking slug"
      assert html =~ "Ada Lovelace"
      assert html =~ "ada-lovelace"
    end

    test "users tab renders a placeholder for users without a profile", %{
      conn: conn,
      admin: admin,
      other_admin: other_admin,
      regular: regular
    } do
      # Give every other user a profile, so `regular` — inserted without one in
      # the setup block — is the only source of placeholders.
      insert(:profile, user: admin, full_name: "Grace Hopper", username: "grace-hopper")
      insert(:profile, user: other_admin, full_name: "Alan Turing", username: "alan-turing")

      {:ok, _lv, html} = live(conn, ~p"/admin/users")

      assert html =~ regular.email
      assert html =~ "Grace Hopper"
      assert html =~ "Alan Turing"

      # Exactly two placeholders: display name and booking slug for `regular`.
      assert length(Regex.scan(~r/—/, html)) == 2
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

      # The email must sit inside the single interpolated question, not merely
      # somewhere on the page — guards against the sentence being split back
      # into gettext fragments around the value. Scope to the modal body: the
      # row's button carries a contiguous "Promote <email> to admin" aria-label,
      # so a full-page match would pass even if the body were re-fragmented.
      # (The en translation drops the trailing "?".)
      modal_body = lv |> element("#confirm-role-change-modal .modal-body") |> render()
      assert modal_body =~ "Promote #{regular.email} to admin"
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

      # The email must sit inside the single interpolated question for the
      # non-self demote variant — guards against the sentence being split back
      # into gettext fragments around the value. Scope to the modal body: the
      # row's button carries a contiguous "Demote <email> from admin" aria-label,
      # so a full-page match would pass even if the body were re-fragmented.
      # (The en translation drops the trailing "?".)
      modal_body = lv |> element("#confirm-role-change-modal .modal-body") |> render()
      assert modal_body =~ "Demote #{other_admin.email} from admin"

      lv |> confirm_demote() |> render_click()

      refute Repo.reload!(other_admin).is_admin
    end

    test "demote button is replaced by a note when the actor is the only admin",
         %{conn: conn, admin: admin} do
      # Demote every admin except the current user, leaving them as the only
      # admin. The UI must offer no way to demote — instead an inline note
      # explains why.
      AdminUserQueries.list_admins()
      |> Enum.reject(&(&1.id == admin.id))
      |> Enum.each(fn other -> AdminUserQueries.set_admin(other, false) end)

      {:ok, lv, html} = live(conn, ~p"/admin/users")

      # No active demote button for the self row.
      refute has_element?(lv, ~s|button[phx-click="request_demote"][phx-value-id="#{admin.id}"]|)

      # The inline note is visible.
      assert html =~ "last-admin-self-note"
      assert html =~ "No other admin can sign in."

      # And the user remains an admin.
      assert Repo.reload!(admin).is_admin
    end

    test "self-demote is hidden and refused when the only other admin cannot sign in",
         %{conn: conn, admin: admin, other_admin: other_admin} do
      # Another is_admin row exists, but it is unverified, so nobody else could
      # reach the admin area once the current admin is demoted.
      {:ok, _unverified} =
        other_admin |> Changeset.change(verified_at: nil) |> Repo.update()

      {:ok, lv, html} = live(conn, ~p"/admin/users")

      refute has_element?(lv, ~s|button[phx-click="request_demote"][phx-value-id="#{admin.id}"]|)
      assert html =~ "last-admin-self-note"

      # A forged event skipping the hidden button is refused by the domain.
      html = render_click(lv, "demote_user", %{"id" => to_string(admin.id)})

      assert html =~ "Cannot demote this admin: no other admin can sign in."
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
      {:ok, _user} = AdminUserQueries.set_admin(admin, false)

      conn = get(conn, ~p"/admin")

      assert redirected_to(conn) == ~p"/dashboard"
      assert Flash.get(conn.assigns.flash, :error) == "Admin access required."
    end

    test "after self-demote, the dashboard dropdown no longer shows Admin Settings",
         %{conn: conn, admin: admin} do
      # The dashboard requires onboarding to be complete before it renders.
      {:ok, admin} =
        admin
        |> Changeset.change(onboarding_completed_at: DateTime.utc_now(:second))
        |> Repo.update()

      {:ok, _user} = AdminUserQueries.set_admin(admin, false)

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

  defp stat_cards(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".grid.mb-8 > *")
    |> Enum.map(fn card ->
      [label, value] =
        card |> LazyHTML.query("p") |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      {label, value}
    end)
  end
end
