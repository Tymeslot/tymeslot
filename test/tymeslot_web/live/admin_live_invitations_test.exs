defmodule TymeslotWeb.AdminLiveInvitationsTest do
  use TymeslotWeb.ConnCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :live
  @moduletag :auth

  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import Tymeslot.AdminPageHelpers

  alias Ecto.Changeset
  alias Tymeslot.Auth
  alias Tymeslot.Auth.{Invitations, UserSchema}
  alias Tymeslot.Repo
  alias Tymeslot.Test.OAuthProviderStub
  alias Tymeslot.Workers.EmailWorker

  setup :admin_conn

  test "inviting an address creates the account and lists it as invited", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/admin/users")

    lv
    |> form("#invite-user-form", invite: %{email: "newcomer@example.com"})
    |> render_submit()

    assert %UserSchema{} = user = Auth.get_user_by_email("newcomer@example.com")
    assert Invitations.pending?(user)
    assert [_job] = invitation_jobs()

    html = render(lv)
    assert html =~ "Invitation sent to newcomer@example.com."
    assert has_element?(lv, ~s|[data-testid="invitation-pending-badge"]|)
    assert has_element?(lv, ~s|button[phx-click="resend_invitation"][phx-value-id="#{user.id}"]|)
  end

  test "an address that already has an account is refused on the form", %{conn: conn} do
    existing = insert(:user)
    {:ok, lv, _html} = live(conn, ~p"/admin/users")

    html =
      lv
      |> form("#invite-user-form", invite: %{email: existing.email})
      |> render_submit()

    assert html =~ "An account with this email address already exists."
    assert invitation_jobs() == []
  end

  test "resend issues a fresh link", %{conn: conn, admin: admin} do
    {:ok, user} = Invitations.invite(admin, "again@example.com")
    first_hash = user.invitation_token_hash
    Repo.delete_all(Oban.Job)

    {:ok, lv, _html} = live(conn, ~p"/admin/users")

    html =
      lv
      |> element(~s|button[phx-click="resend_invitation"][phx-value-id="#{user.id}"]|)
      |> render_click()

    assert html =~ "A new invitation is on its way to again@example.com."
    assert Repo.get!(UserSchema, user.id).invitation_token_hash != first_hash
    assert [_job] = invitation_jobs()
  end

  test "an expired invitation is marked as such", %{conn: conn, admin: admin} do
    {:ok, user} = Invitations.invite(admin, "late@example.com")
    eight_days_ago = DateTime.add(DateTime.utc_now(:second), -8, :day)

    user |> Changeset.change(invitation_sent_at: eight_days_ago) |> Repo.update!()

    {:ok, lv, _html} = live(conn, ~p"/admin/users")

    assert has_element?(lv, ~s|[data-testid="invitation-expired-badge"]|)
    refute has_element?(lv, ~s|[data-testid="invitation-pending-badge"]|)
  end

  test "with no sign-in method switched on, the form is replaced by an explanation", %{
    conn: conn
  } do
    password_auth_off()

    {:ok, lv, _html} = live(conn, ~p"/admin/users")

    refute has_element?(lv, "#invite-user-form")
    assert has_element?(lv, ~s|[data-testid="invitations-unavailable"]|)
  end

  test "with password sign-in off, a social sign-in provider keeps the form", %{conn: conn} do
    password_auth_off()
    OAuthProviderStub.setup_providers(%{})

    {:ok, lv, _html} = live(conn, ~p"/admin/users")

    assert has_element?(lv, "#invite-user-form")
    refute has_element?(lv, ~s|[data-testid="invitations-unavailable"]|)
  end

  defp password_auth_off do
    original = Application.get_env(:tymeslot, :password_auth_enabled)
    Application.put_env(:tymeslot, :password_auth_enabled, false)
    on_exit(fn -> Application.put_env(:tymeslot, :password_auth_enabled, original) end)
  end

  defp invitation_jobs do
    Enum.filter(
      all_enqueued(worker: EmailWorker),
      &(&1.args["action"] == "send_account_invitation")
    )
  end
end
