defmodule TymeslotWeb.InvitationSocialJourneyTest do
  @moduledoc """
  Accepting an invitation with a social sign-in, driven through the router:
  the invitation page's provider button, the provider's authorise redirect
  and its callback. Only the provider's HTTP endpoints are stubbed
  (`Tymeslot.Test.OAuthProviderStub`); state, PKCE, the link and the session
  are all real.
  """

  use TymeslotWeb.ConnCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth
  @moduletag :controllers
  @moduletag :integration

  import Tymeslot.Factory, only: [insert: 2]
  import Tymeslot.RateLimiterTestHelpers, only: [exhaust_limit!: 2]
  import Tymeslot.Test.OAuthProviderStub

  alias Ecto.Changeset
  alias Phoenix.Flash
  alias Tymeslot.Auth.{Invitations, UserSchema}
  alias Tymeslot.Emails.EmailScheduler.LinkArg
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  setup :setup_providers

  setup do
    Application.put_env(:tymeslot, :enable_admin_ui, true)
    admin = insert(:user, is_admin: true)
    {:ok, invitee} = Invitations.invite(admin, "invitee@example.com")
    {:ok, invitee: invitee, path: invitation_path(invitee)}
  end

  test "the invitee accepts with GitHub and is signed in to the invited account", %{
    invitee: invitee,
    path: path
  } do
    # The provider's address differs from the invited one: the link alone
    # proves the invitee, and the invited address stays the account's email.
    stub_github(%{"id" => 7001, "name" => "Ada", "email" => "ada@elsewhere.example"}, [
      %{"email" => "ada@elsewhere.example", "primary" => true, "verified" => true}
    ])

    page = build_conn() |> get(path) |> html_response(200)
    assert page =~ ~s|action="#{path}/github"|

    conn = accept_with(build_conn(), path, "github")

    assert redirected_to(conn) == Config.success_redirect_path()
    assert get_session(conn, :user_token)
    assert Flash.get(conn.assigns.flash, :success) =~ "GitHub"

    user = Repo.get!(UserSchema, invitee.id)
    assert user.github_user_id == "7001"
    assert user.provider == "github"
    assert user.email == "invitee@example.com"
    assert %DateTime{} = user.verified_at
    refute Invitations.pending?(user)

    # The link is spent.
    again = get(build_conn(), path)
    assert redirected_to(again) == ~p"/auth/login"
    assert Flash.get(again.assigns.flash, :error) =~ "no longer valid"

    # And the identity now signs in to the account the ordinary way.
    signed_in = sign_in(build_conn(), "github")
    assert redirected_to(signed_in) == Config.success_redirect_path()
    assert get_session(signed_in, :user_token)
  end

  test "with public registration closed, the invitee still accepts with GitHub", %{
    invitee: invitee,
    path: path
  } do
    original = Application.get_env(:tymeslot, :registration_enabled, true)
    Application.put_env(:tymeslot, :registration_enabled, false)
    on_exit(fn -> Application.put_env(:tymeslot, :registration_enabled, original) end)

    stub_github(%{"id" => 7101, "email" => "closed@example.com"}, [
      %{"email" => "closed@example.com", "primary" => true, "verified" => true}
    ])

    # Registration really is closed: a new identity signing in the ordinary
    # way is turned away.
    stranger = sign_in(build_conn(), "github")
    refute get_session(stranger, :user_token)
    refute Repo.get_by(UserSchema, github_user_id: "7101")

    conn = accept_with(build_conn(), path, "github")

    assert redirected_to(conn) == Config.success_redirect_path()
    assert get_session(conn, :user_token)
    assert Repo.get!(UserSchema, invitee.id).github_user_id == "7101"
  end

  test "an identity that already signs in to another account is refused", %{
    invitee: invitee,
    path: path
  } do
    insert(:user, provider: "google", google_user_id: "g-taken")
    stub_google(%{"id" => "g-taken", "email" => "taken@example.com", "verified_email" => true})

    conn = accept_with(build_conn(), path, "google")

    assert redirected_to(conn) == path
    assert Flash.get(conn.assigns.flash, :error) =~ "already signs in to another"
    refute get_session(conn, :user_token)

    user = Repo.get!(UserSchema, invitee.id)
    assert Invitations.pending?(user)
    assert user.google_user_id == nil
  end

  test "an expired invitation is refused at the callback", %{invitee: invitee, path: path} do
    stub_sso(%{"sub" => "sub-late", "email" => "late@example.com", "email_verified" => true})
    start = post(build_conn(), path <> "/oauth")
    %{"state" => state} = start |> redirected_to(302) |> authorise_params()

    eight_days_ago = DateTime.add(DateTime.utc_now(:second), -8, :day)

    invitee
    |> Changeset.change(invitation_sent_at: eight_days_ago)
    |> Repo.update!()

    conn =
      start
      |> recycle()
      |> get("/auth/oauth/callback", %{"code" => "provider-code", "state" => state})

    assert redirected_to(conn) == ~p"/auth/login"
    assert Flash.get(conn.assigns.flash, :error) =~ "expired"
    assert Repo.get!(UserSchema, invitee.id).provider_uid == nil
  end

  test "an ordinary sign-in started after an abandoned acceptance does not accept it", %{
    invitee: invitee,
    path: path
  } do
    stub_github(%{"id" => 7002, "email" => "drifter@example.com"}, [
      %{"email" => "drifter@example.com", "primary" => true, "verified" => true}
    ])

    abandoned = post(build_conn(), path <> "/github")
    assert redirected_to(abandoned, 302) =~ "github.com"

    conn = abandoned |> recycle() |> sign_in("github")

    assert redirected_to(conn) == "/auth/complete-registration"
    assert Invitations.pending?(Repo.get!(UserSchema, invitee.id))
  end

  test "an ordinary sign-in with the invited address is sent to the invitation link", %{
    invitee: invitee
  } do
    stub_github(%{"id" => 7003, "email" => "invitee@example.com"}, [
      %{"email" => "invitee@example.com", "primary" => true, "verified" => true}
    ])

    conn = sign_in(build_conn(), "github")

    assert redirected_to(conn) == ~p"/?auth=login"
    assert Flash.get(conn.assigns.flash, :info) =~ "Open the invitation link we emailed you"
    refute get_session(conn, :user_token)

    user = Repo.get!(UserSchema, invitee.id)
    assert Invitations.pending?(user)
    assert user.github_user_id == nil
  end

  test "an address over the acceptance limit is refused at the callback", %{
    invitee: invitee,
    path: path
  } do
    stub_github(%{"id" => 7004, "email" => "busy@example.com"}, [
      %{"email" => "busy@example.com", "primary" => true, "verified" => true}
    ])

    conn = %{build_conn() | remote_ip: {10, 77, 0, 4}}
    start = post(conn, path <> "/github")
    %{"state" => state} = start |> redirected_to(302) |> authorise_params()

    exhaust_limit!(:invitation_accept, "10.77.0.4")

    conn =
      start
      |> recycle()
      |> Map.put(:remote_ip, {10, 77, 0, 4})
      |> get("/auth/github/callback", %{"code" => "provider-code", "state" => state})

    assert redirected_to(conn) == path
    assert Flash.get(conn.assigns.flash, :error) =~ "Too many"
    refute get_session(conn, :user_token)

    user = Repo.get!(UserSchema, invitee.id)
    assert Invitations.pending?(user)
    assert user.github_user_id == nil
  end

  test "with password sign-in off, the page offers the providers alone", %{path: path} do
    original = Application.get_env(:tymeslot, :password_auth_enabled)
    Application.put_env(:tymeslot, :password_auth_enabled, false)
    on_exit(fn -> Application.put_env(:tymeslot, :password_auth_enabled, original) end)

    page = build_conn() |> get(path) |> html_response(200)

    refute page =~ ~s|id="accept-invitation-form"|
    assert page =~ ~s|action="#{path}/github"|
  end

  test "a disabled provider is not started", %{path: path} do
    social_auth = Application.get_env(:tymeslot, :social_auth)
    Application.put_env(:tymeslot, :social_auth, Keyword.put(social_auth, :github_enabled, false))

    conn = post(build_conn(), path <> "/github")

    assert redirected_to(conn) == path
    assert Flash.get(conn.assigns.flash, :error) =~ "not available"
  end

  # Follows the invitation page's provider button through the provider's
  # authorise redirect and back to its callback.
  defp accept_with(conn, path, provider) do
    start = post(conn, path <> "/" <> provider)
    %{"state" => state} = start |> redirected_to(302) |> authorise_params()

    start
    |> recycle()
    |> get("/auth/#{provider}/callback", %{"code" => "provider-code", "state" => state})
  end

  defp invitation_path(invitee) do
    job =
      Enum.find(
        all_enqueued(worker: EmailWorker),
        &(&1.args["action"] == "send_account_invitation" and &1.args["user_id"] == invitee.id)
      )

    {:ok, url} = LinkArg.fetch(job.args, "invitation_url")
    URI.parse(url).path
  end
end
