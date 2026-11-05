defmodule Tymeslot.Auth.InvitationsTest do
  use Tymeslot.DataCase, async: false

  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth

  alias Tymeslot.Auth
  alias Tymeslot.Auth.{AccountTokens, Invitations, UserSchema}
  alias Tymeslot.Emails.EmailScheduler.LinkArg
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  @ip [ip: "203.0.113.7", user_agent: "test"]
  @password "Sup3r-secret!"

  setup do
    Application.put_env(:tymeslot, :enable_admin_ui, true)
    {:ok, admin: insert(:user, is_admin: true)}
  end

  describe "invite/2" do
    test "creates an unverified account with a profile and queues the invitation", %{
      admin: admin
    } do
      assert {:ok, user} = Invitations.invite(admin, "  New.Person@Example.com ")

      user = Repo.get!(UserSchema, user.id)
      assert user.email == "new.person@example.com"
      assert user.verified_at == nil
      assert user.password_hash == nil
      assert Invitations.pending?(user)
      refute Invitations.expired?(user)
      assert Profiles.get_profile(user.id)

      assert [job] = invitation_jobs()
      assert job.args["user_id"] == user.id
      assert job.args["token_hash"] == user.invitation_token_hash
      assert {:ok, "http" <> _rest = url} = LinkArg.fetch(job.args, "invitation_url")
      assert url =~ "/auth/invitation/"
    end

    test "refuses an actor who is not an admin" do
      regular = insert(:user, is_admin: false)

      assert {:error, :forbidden} = Invitations.invite(regular, "someone@example.com")
      assert Auth.get_user_by_email("someone@example.com") == nil
      assert invitation_jobs() == []
    end

    test "refuses an address that already has an account", %{admin: admin} do
      existing = insert(:user)

      assert {:error, :email_taken} = Invitations.invite(admin, String.upcase(existing.email))
      assert invitation_jobs() == []
    end

    test "refuses an invalid address", %{admin: admin} do
      assert {:error, :invalid_email} = Invitations.invite(admin, "not-an-email")
      assert invitation_jobs() == []
    end

    test "refuses while password sign-in is switched off", %{admin: admin} do
      with_password_auth_off(fn ->
        assert {:error, :password_auth_disabled} =
                 Invitations.invite(admin, "someone@example.com")
      end)

      assert Auth.get_user_by_email("someone@example.com") == nil
    end
  end

  describe "resend/2" do
    test "replaces the token, so only the newest link works", %{admin: admin} do
      {:ok, user} = Invitations.invite(admin, "resend@example.com")
      first_token = token_from_job(user)
      Repo.delete_all(Oban.Job)

      assert {:ok, _user} = Invitations.resend(admin, user.id)
      second_token = token_from_job(user)

      assert first_token != second_token
      assert {:error, :invalid_token} = Invitations.fetch(first_token)
      assert {:ok, %UserSchema{id: id}} = Invitations.fetch(second_token)
      assert id == user.id
    end

    test "refuses a user with no pending invitation", %{admin: admin} do
      regular = insert(:user)

      assert {:error, :not_invited} = Invitations.resend(admin, regular.id)
    end
  end

  describe "accept/4" do
    setup %{admin: admin} do
      {:ok, user} = Invitations.invite(admin, "invitee@example.com")
      {:ok, user: user, token: token_from_job(user)}
    end

    test "sets the password, verifies the account and spends the link", %{
      user: user,
      token: token
    } do
      assert {:ok, accepted} = Invitations.accept(token, @password, @password, @ip)
      assert accepted.id == user.id

      user = Repo.get!(UserSchema, user.id)
      assert %DateTime{} = user.verified_at
      refute Invitations.pending?(user)

      assert {:ok, %UserSchema{id: id}, _message} =
               Auth.authenticate_user("invitee@example.com", @password, @ip)

      assert id == user.id

      assert {:error, :invalid_token} = Invitations.accept(token, @password, @password, @ip)
    end

    test "rejects a weak password and keeps the invitation pending", %{
      user: user,
      token: token
    } do
      assert {:error, :invalid_input, message} = Invitations.accept(token, "short", "short", @ip)
      assert is_binary(message) and message != ""

      user = Repo.get!(UserSchema, user.id)
      assert user.password_hash == nil
      assert Invitations.pending?(user)
    end

    test "rejects a mismatched confirmation", %{token: token} do
      assert {:error, :invalid_input, _message} =
               Invitations.accept(token, @password, @password <> "x", @ip)
    end

    test "refuses an expired link", %{user: user, token: token} do
      expire_invitation(user)

      assert {:error, :token_expired} = Invitations.fetch(token)
      assert {:error, :token_expired} = Invitations.accept(token, @password, @password, @ip)
      assert Invitations.expired?(Repo.get!(UserSchema, user.id))
    end

    test "refuses while password sign-in is switched off", %{token: token} do
      with_password_auth_off(fn ->
        assert {:error, :password_auth_disabled} =
                 Invitations.accept(token, @password, @password, @ip)
      end)
    end
  end

  test "a password reset through forgot-password revokes a pending invitation", %{admin: admin} do
    {:ok, user} = Invitations.invite(admin, "forgetful@example.com")
    token = token_from_job(user)

    {:ok, user_with_reset, reset_token} =
      AccountTokens.issue(:reset, Repo.get!(UserSchema, user.id))

    assert {:ok, _user, _message} = Auth.reset_password(reset_token, @password, @password, @ip)
    refute Invitations.pending?(Repo.get!(UserSchema, user_with_reset.id))
    assert {:error, :invalid_token} = Invitations.fetch(token)
  end

  test "the purge of stale unverified accounts leaves invited accounts alone", %{admin: admin} do
    {:ok, user} = Invitations.invite(admin, "patient@example.com")
    long_ago = DateTime.add(DateTime.utc_now(:second), -90, :day)

    Repo.update_all(
      from(u in UserSchema, where: u.id == ^user.id),
      set: [inserted_at: long_ago, invitation_sent_at: long_ago]
    )

    assert {0, nil} = Auth.purge_unverified_accounts(7)
    assert Repo.get(UserSchema, user.id)
  end

  defp invitation_jobs do
    Enum.filter(
      all_enqueued(worker: EmailWorker),
      &(&1.args["action"] == "send_account_invitation")
    )
  end

  defp token_from_job(user) do
    job = Enum.find(invitation_jobs(), &(&1.args["user_id"] == user.id))
    {:ok, url} = LinkArg.fetch(job.args, "invitation_url")
    url |> URI.parse() |> Map.fetch!(:path) |> Path.basename()
  end

  defp expire_invitation(user) do
    eight_days_ago = DateTime.add(DateTime.utc_now(:second), -8, :day)

    Repo.update_all(from(u in UserSchema, where: u.id == ^user.id),
      set: [invitation_sent_at: eight_days_ago]
    )
  end

  defp with_password_auth_off(fun) do
    original = Application.get_env(:tymeslot, :password_auth_enabled)
    Application.put_env(:tymeslot, :password_auth_enabled, false)

    try do
      fun.()
    after
      Application.put_env(:tymeslot, :password_auth_enabled, original)
    end
  end
end
