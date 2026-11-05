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

  alias Phoenix.Flash
  alias Tymeslot.Auth
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Notifications.EmailHandlers
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

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
