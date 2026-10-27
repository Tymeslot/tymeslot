defmodule TymeslotWeb.AccountDeletion.FrozenAccountTest do
  use TymeslotWeb.ConnCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth
  @moduletag :integration

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Auth.{UserQueries, UserSchema}
  alias Tymeslot.Infrastructure.PubSub
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.AccountDeletionWorker

  @password "Password123!"

  setup do
    RateLimiter.clear_all()
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))

    insert(:profile,
      user: user,
      username: "frozen-#{System.unique_integer([:positive])}",
      full_name: "Frieda Frozenfield"
    )

    insert(:meeting_type, user: user, name: "Secret Strategy Session")
    %{user: user}
  end

  defp freeze(user, days \\ 14) do
    now = DateTime.utc_now(:second)
    at = DateTime.add(now, days, :day)
    {:ok, pending} = UserQueries.mark_deletion_scheduled(user, now, at)
    {:ok, _job} = AccountDeletionWorker.schedule(pending.id, at)
    pending
  end

  # A pending account whose date has passed: the deletion is due.
  defp freeze_overdue(user), do: freeze(user, -1)

  describe "a signed-in account pending deletion" do
    test "is sent to the restore page from every signed-in route", %{user: user} do
      pending = freeze(user)

      for path <- [
            "/dashboard",
            "/dashboard/account",
            "/dashboard/settings",
            "/onboarding",
            "/api/slack/oauth/start"
          ] do
        conn =
          build_conn() |> init_test_session(%{}) |> log_in_user(pending) |> get(path)

        assert redirected_to(conn) == "/auth/restore", "#{path} did not go to the restore page"
      end
    end

    test "is sent to the restore page by a live navigation, which skips the plugs",
         %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      freeze(user)

      assert {:error, {:redirect, %{to: "/auth/restore"}}} =
               live_redirect(view, to: ~p"/dashboard/settings")
    end

    test "sees only the date, a restore button and a sign-out button", %{conn: conn, user: user} do
      pending = freeze(user)
      html = conn |> log_in_user(pending) |> get(~p"/auth/restore") |> html_response(200)

      assert html =~ "in the process of being deleted"
      assert html =~ "scheduled for"
      assert html =~ Integer.to_string(pending.deletion_scheduled_at.year)
      assert html =~ "Restore my account"
      assert html =~ "Sign out"
      refute html =~ "Secret Strategy Session"
      refute html =~ "Frieda Frozenfield"
      refute html =~ pending.email
    end

    test "names the deletion date as the user's own calendar day", %{conn: conn} do
      user = insert(:user)
      insert(:profile, user: user, username: "kiritimati", timezone: "Pacific/Kiritimati")
      at = ~U[2036-10-16 12:00:00Z]
      {:ok, pending} = UserQueries.mark_deletion_scheduled(user, DateTime.utc_now(:second), at)

      html = conn |> log_in_user(pending) |> get(~p"/auth/restore") |> html_response(200)

      assert html =~ "17 October 2036"
      refute html =~ "16 October 2036"
    end

    test "restores the account and goes on to the dashboard", %{conn: conn, user: user} do
      pending = freeze(user)
      conn = conn |> log_in_user(pending) |> post(~p"/auth/restore")

      assert redirected_to(conn) == "/dashboard"
      assert Repo.get(UserSchema, user.id).deletion_scheduled_at == nil
      refute_enqueued(worker: AccountDeletionWorker)
    end

    test "signs out from the restore page", %{conn: conn, user: user} do
      pending = freeze(user)
      conn = conn |> log_in_user(pending) |> delete(~p"/auth/logout")

      assert redirected_to(conn) == "/"
      assert Repo.get(UserSchema, user.id).deletion_scheduled_at
    end
  end

  describe "an account whose deletion date has passed" do
    test "is told it can no longer be restored and can only sign out", %{conn: conn, user: user} do
      pending = freeze_overdue(user)
      html = conn |> log_in_user(pending) |> get(~p"/auth/restore") |> html_response(200)

      assert html =~ "can no longer be restored"
      assert html =~ "Sign out"
      refute html =~ "Restore my account"
      refute html =~ "Secret Strategy Session"
      refute html =~ pending.email
    end

    test "is still sent to the restore page from the dashboard", %{conn: conn, user: user} do
      pending = freeze_overdue(user)
      conn = conn |> log_in_user(pending) |> get(~p"/dashboard")
      assert redirected_to(conn) == "/auth/restore"
    end

    test "posting a restore shows the same message and changes nothing",
         %{conn: conn, user: user} do
      pending = freeze_overdue(user)
      conn = conn |> log_in_user(pending) |> post(~p"/auth/restore")
      html = html_response(conn, 200)

      assert html =~ "can no longer be restored"
      refute html =~ "Restore my account"
      assert Repo.get(UserSchema, user.id).deletion_scheduled_at
    end
  end

  # The restore page is served by a plain controller, so no hook mounts on
  # it: the background video and its motion toggle would be dead weight.
  test "the restore pages carry no background video, unlike a live auth page",
       %{conn: conn, user: user} do
    {:ok, _view, login_html} = live(conn, ~p"/auth/login")
    assert login_html =~ ~s(phx-hook="AuthVideo")
    assert login_html =~ ~s(id="background-motion-toggle")

    html = conn |> log_in_user(freeze(user)) |> get(~p"/auth/restore") |> html_response(200)

    assert html =~ "Restore my account"
    refute html =~ ~s(phx-hook="AuthVideo")
    refute html =~ ~s(id="background-motion-toggle")
    refute html =~ "<video"
  end

  test "a restore posted for an account that is already gone goes to the login page",
       %{conn: conn, user: user} do
    pending = freeze(user)
    conn = log_in_user(conn, pending)
    Repo.delete!(user)

    assert conn |> post(~p"/auth/restore") |> redirected_to() == "/auth/login"
  end

  test "signing in during the grace period leads to the restore page", %{conn: conn, user: user} do
    pending = freeze(user)

    conn = post(conn, ~p"/auth/session", %{"email" => pending.email, "password" => @password})
    assert redirected_to(conn) == "/dashboard"

    conn = conn |> recycle() |> get(~p"/dashboard")
    assert redirected_to(conn) == "/auth/restore"
  end

  test "an active account is sent on from the restore page", %{conn: conn, user: user} do
    conn = conn |> log_in_user(user) |> get(~p"/auth/restore")
    assert redirected_to(conn) == "/dashboard"
  end

  test "a visitor is sent to the login page", %{conn: conn} do
    assert conn |> get(~p"/auth/restore") |> redirected_to() == "/auth/login"
  end

  test "an open tab leaves when the deletion is requested from another one",
       %{conn: conn, user: user} do
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/dashboard/account")

    PubSub.broadcast_account_deletion_requested(user.id)

    assert_redirect(view, "/auth/login")
  end
end
