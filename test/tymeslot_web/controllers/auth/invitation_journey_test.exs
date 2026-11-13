defmodule TymeslotWeb.InvitationJourneyTest do
  @moduledoc """
  The whole invitation journey: an admin invites an address from the users
  tab, the invitation email is delivered with its link, and the invitee
  follows it, chooses a password and lands signed in.
  """

  use TymeslotWeb.ConnCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth
  @moduletag :integration

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AdminPageHelpers
  import Tymeslot.Factory, only: [insert: 1]

  alias Phoenix.Flash
  alias Tymeslot.Auth
  alias Tymeslot.Auth.{Invitations, UserSchema}
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Notifications.EmailHandlers
  alias Tymeslot.Repo
  alias Tymeslot.Workers.{AccountDeletionWorker, EmailWorker}

  @password "Sup3r-secret!"

  setup :admin_conn
  setup :verify_on_exit!

  test "an invited user accepts, chooses a password and is signed in", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/admin/users")

    lv
    |> form("#invite-user-form", invite: %{email: "invitee@example.com"})
    |> render_submit()

    url = deliver_invitation()
    path = URI.parse(url).path

    invitee = build_conn()
    page = invitee |> get(path) |> html_response(200)
    assert page =~ "invitee@example.com"
    assert page =~ "Set password and sign in"

    conn =
      post(invitee, path, %{
        "invitation" => %{"password" => @password, "password_confirmation" => @password}
      })

    assert redirected_to(conn) == Config.success_redirect_path()
    assert get_session(conn, :user_token)

    user = Auth.get_user_by_email("invitee@example.com")
    assert %DateTime{} = Repo.get!(UserSchema, user.id).verified_at

    # The link is spent: following it again is refused.
    again = get(build_conn(), path)
    assert redirected_to(again) == ~p"/auth/login"
    assert Flash.get(again.assigns.flash, :error) =~ "no longer valid"
  end

  test "with public registration closed, the invitee still accepts and is signed in", %{
    conn: conn
  } do
    close_registration()

    # Registration really is closed: the sign-up form refuses a stranger.
    assert {:error, :registration_disabled, _message} =
             Auth.register_user(
               %{
                 "email" => "stranger@example.com",
                 "password" => @password,
                 "password_confirmation" => @password,
                 "terms_accepted" => "true"
               },
               ip: "203.0.113.9",
               user_agent: "test"
             )

    {:ok, lv, _html} = live(conn, ~p"/admin/users")

    lv
    |> form("#invite-user-form", invite: %{email: "closed@example.com"})
    |> render_submit()

    path = URI.parse(deliver_invitation()).path

    conn =
      post(build_conn(), path, %{
        "invitation" => %{"password" => @password, "password_confirmation" => @password}
      })

    assert redirected_to(conn) == Config.success_redirect_path()
    assert get_session(conn, :user_token)
    assert Repo.get!(UserSchema, Auth.get_user_by_email("closed@example.com").id).verified_at
  end

  test "a password that breaks the rules re-renders the form with the reason", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/admin/users")

    lv
    |> form("#invite-user-form", invite: %{email: "weak@example.com"})
    |> render_submit()

    path = URI.parse(deliver_invitation()).path

    html =
      build_conn()
      |> post(path, %{
        "invitation" => %{"password" => "short", "password_confirmation" => "short"}
      })
      |> html_response(200)

    assert html =~ ~s|role="alert"|
    user = Auth.get_user_by_email("weak@example.com")
    assert Repo.get!(UserSchema, user.id).password_hash == nil
  end

  test "submitting the password form empty shows the reason inline", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/admin/users")

    lv
    |> form("#invite-user-form", invite: %{email: "empty@example.com"})
    |> render_submit()

    path = URI.parse(deliver_invitation()).path

    page = build_conn() |> get(path) |> html_response(200) |> LazyHTML.from_document()
    assert Enum.count(LazyHTML.query(page, "#accept-invitation-form[novalidate]")) == 1

    html =
      build_conn()
      |> post(path, %{"invitation" => %{"password" => "", "password_confirmation" => ""}})
      |> html_response(200)

    alert = html |> LazyHTML.from_document() |> LazyHTML.query("p[role=alert]")
    assert LazyHTML.text(alert) =~ ~r/\S/

    assert Repo.get!(UserSchema, Auth.get_user_by_email("empty@example.com").id).password_hash ==
             nil
  end

  for {label, body} <- [
        {"a string where the form is expected", %{"invitation" => "not-a-form"}},
        {"a map where the password is expected",
         %{"invitation" => %{"password" => %{"x" => "y"}, "password_confirmation" => ["z"]}}}
      ] do
    test "a crafted body with #{label} re-renders the form instead of crashing", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/users")

      lv
      |> form("#invite-user-form", invite: %{email: "crafted@example.com"})
      |> render_submit()

      path = URI.parse(deliver_invitation()).path

      html =
        build_conn()
        |> post(path, unquote(Macro.escape(body)))
        |> html_response(200)

      assert html =~ ~s|role="alert"|
      user = Auth.get_user_by_email("crafted@example.com")
      assert Repo.get!(UserSchema, user.id).password_hash == nil
    end
  end

  test "an admin cancels the invitation, and the emailed link then refuses", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/admin/users")

    lv
    |> form("#invite-user-form", invite: %{email: "jon@exmaple.com"})
    |> render_submit()

    path = URI.parse(deliver_invitation()).path
    user = Auth.get_user_by_email("jon@exmaple.com")

    lv
    |> element(~s|button[phx-click="request_cancel_invitation"][phx-value-id="#{user.id}"]|)
    |> render_click()

    assert has_element?(
             lv,
             "#confirm-cancel-invitation-modal",
             "The invitation link stops working"
           )

    html =
      lv
      |> element(~s|#confirm-cancel-invitation-modal button[phx-click="cancel_invitation"]|)
      |> render_click()

    assert html =~ "The invitation to jon@exmaple.com is cancelled."
    refute has_element?(lv, "#confirm-cancel-invitation-modal")
    assert_enqueued(worker: AccountDeletionWorker, args: %{"user_id" => user.id})

    shown = get(build_conn(), path)
    assert redirected_to(shown) == ~p"/auth/login"
    assert Flash.get(shown.assigns.flash, :error) =~ "no longer valid"

    accepted =
      post(build_conn(), path, %{
        "invitation" => %{"password" => @password, "password_confirmation" => @password}
      })

    assert redirected_to(accepted) == ~p"/auth/login"
    refute get_session(accepted, :user_token)
    assert Repo.get!(UserSchema, user.id).password_hash == nil

    # Once the deletion has run, the address can be invited again.
    assert :ok = perform_job(AccountDeletionWorker, %{"user_id" => user.id})
    assert Auth.get_user_by_email("jon@exmaple.com") == nil
  end

  test "a non-admin's revoke is refused and the link keeps working", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/admin/users")

    lv
    |> form("#invite-user-form", invite: %{email: "kept@example.com"})
    |> render_submit()

    path = URI.parse(deliver_invitation()).path
    user = Auth.get_user_by_email("kept@example.com")

    assert {:error, :forbidden} = Invitations.revoke(insert(:user), user.id)

    page = build_conn() |> get(path) |> html_response(200)
    assert page =~ "Set password and sign in"
  end

  defp close_registration do
    original = Application.get_env(:tymeslot, :registration_enabled, true)
    Application.put_env(:tymeslot, :registration_enabled, false)
    on_exit(fn -> Application.put_env(:tymeslot, :registration_enabled, original) end)
  end

  # Runs the queued invitation job through its handler, as the worker would,
  # and returns the link the email carried.
  defp deliver_invitation do
    [job] =
      Enum.filter(
        all_enqueued(worker: EmailWorker),
        &(&1.args["action"] == "send_account_invitation")
      )

    parent = self()

    expect(EmailServiceMock, :send_account_invitation, fn user, url ->
      send(parent, {:invitation, user.email, url})
      {:ok, "sent"}
    end)

    assert :ok = EmailHandlers.execute_email_action("send_account_invitation", job.args)
    assert_receive {:invitation, _email, url}
    url
  end
end
