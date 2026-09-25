defmodule Tymeslot.Auth.EmailChangeTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth

  alias Ecto.Changeset
  alias Tymeslot.Auth
  alias Tymeslot.Auth.{PasswordReset, UserSchema, UserSessionSchema, UserTokenQueries}
  alias Tymeslot.Emails.EmailScheduler.LinkArg
  alias Tymeslot.Security.{Password, Token}
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.Endpoint
  alias TymeslotWeb.Helpers.ClientIP

  import Tymeslot.Factory

  describe "request_email_change/3" do
    setup do
      user = insert(:user)
      {:ok, user: user}
    end

    test "successfully requests email change with valid credentials", %{user: user} do
      new_email = "new.email@example.com"

      assert {:ok, updated_user, _message} =
               Auth.request_email_change(
                 user,
                 new_email,
                 "Password123!",
                 ClientIP.request_opts(%Plug.Conn{})
               )

      assert updated_user.pending_email == new_email
      assert byte_size(updated_user.email_change_token_hash) > 0
      assert %DateTime{} = updated_user.email_change_sent_at

      # Verify both email jobs were enqueued
      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_email_change_verification",
          "user_id" => updated_user.id,
          "new_email" => new_email
        }
      )

      [verification_job] =
        all_enqueued(
          worker: EmailWorker,
          args: %{"action" => "send_email_change_verification", "user_id" => updated_user.id}
        )

      # The emailed link carries the raw token whose hash was persisted on the user.
      assert [_base, emailed_token] =
               String.split(emailed_link(verification_job, "verification_url"), "/email-change/")

      assert Token.hash_token(emailed_token) == updated_user.email_change_token_hash

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_email_change_notification",
          "user_id" => updated_user.id,
          "new_email" => new_email
        }
      )
    end

    test "fails with invalid password", %{user: user} do
      new_email = "new.email@example.com"

      assert {:error, %{current_password: "Current password is incorrect"}} =
               Auth.request_email_change(
                 user,
                 new_email,
                 "wrong_password",
                 ClientIP.request_opts(%Plug.Conn{})
               )
    end

    test "fails with same email as current", %{user: user} do
      assert {:error, %{new_email: "New email must be different from current email"}} =
               Auth.request_email_change(
                 user,
                 user.email,
                 "Password123!",
                 ClientIP.request_opts(%Plug.Conn{})
               )
    end

    test "fails with invalid email format", %{user: user} do
      assert {:error, %{new_email: _message}} =
               Auth.request_email_change(
                 user,
                 "not-an-email",
                 "Password123!",
                 ClientIP.request_opts(%Plug.Conn{})
               )
    end

    test "fails when another user already has the address pending", %{user: user} do
      other_user = insert(:user)

      {:ok, _other} =
        UserTokenQueries.request_email_change(
          other_user,
          "wanted@example.com",
          Token.generate_token()
        )

      assert {:error, %{new_email: "Email address is already in use"}} =
               Auth.request_email_change(
                 user,
                 "wanted@example.com",
                 "Password123!",
                 ClientIP.request_opts(%Plug.Conn{})
               )
    end

    test "reports every malformed field at once", %{user: user} do
      assert {:error, errors} =
               Auth.request_email_change(
                 user,
                 "not-an-email",
                 "",
                 ClientIP.request_opts(%Plug.Conn{})
               )

      assert errors.current_password == "Password is required"
      assert errors.new_email =~ ~r/email/i
    end

    test "checks the current password against the stored hash, not the caller's copy", %{
      user: stale_user
    } do
      {:ok, _user} =
        Auth.update_user_password(
          stale_user,
          "Password123!",
          "NewPass456!",
          "NewPass456!",
          ClientIP.request_opts(%Plug.Conn{})
        )

      assert {:error, %{current_password: "Current password is incorrect"}} =
               Auth.request_email_change(
                 stale_user,
                 "new.email@example.com",
                 "Password123!",
                 ClientIP.request_opts(%Plug.Conn{})
               )

      assert Repo.get!(UserSchema, stale_user.id).pending_email == nil
    end

    test "checks the current password as login does, not against the creation policy" do
      # Set under an older, weaker policy: no uppercase letter, no symbol.
      user = insert(:user, password_hash: Password.hash_password("legacypassword1"))

      assert {:ok, _user, _message} =
               Auth.request_email_change(
                 user,
                 "new.email@example.com",
                 "legacypassword1",
                 ClientIP.request_opts(%Plug.Conn{})
               )
    end

    test "reports a missing current password on its field", %{user: user} do
      assert {:error, %{current_password: "Password is required"}} =
               Auth.request_email_change(
                 user,
                 "new.email@example.com",
                 "",
                 ClientIP.request_opts(%Plug.Conn{})
               )
    end

    test "returns an error, not a crash, for an account with no password" do
      user = insert(:user, provider: "google", password_hash: nil)

      assert {:error, %{current_password: "Current password is incorrect"}} =
               Auth.request_email_change(
                 user,
                 "new.email@example.com",
                 "Anything123!",
                 ClientIP.request_opts(%Plug.Conn{})
               )
    end

    test "fails when email is already taken", %{user: user} do
      other_user = insert(:user)

      assert {:error, %{new_email: "Email address is already in use"}} =
               Auth.request_email_change(
                 user,
                 other_user.email,
                 "Password123!",
                 ClientIP.request_opts(%Plug.Conn{})
               )
    end

    test "overwrites pending change when a new one is requested", %{user: user} do
      first_email = "first@example.com"
      second_email = "second@example.com"

      {:ok, user_with_first, _message} =
        Auth.request_email_change(
          user,
          first_email,
          "Password123!",
          ClientIP.request_opts(%Plug.Conn{})
        )

      assert user_with_first.pending_email == first_email

      # Request again with a different email; the previous pending state should be overwritten
      {:ok, user_with_second, _message} =
        Auth.request_email_change(
          user_with_first,
          second_email,
          "Password123!",
          ClientIP.request_opts(%Plug.Conn{})
        )

      assert user_with_second.pending_email == second_email
    end
  end

  describe "verify_email_change/1" do
    setup do
      user = insert(:user)
      new_email = "new.email@example.com"
      token = Token.generate_token()

      {:ok, user_with_pending} =
        UserTokenQueries.request_email_change(user, new_email, token)

      {:ok, user: user_with_pending, token: token, new_email: new_email}
    end

    test "successfully verifies and completes email change", %{
      user: user,
      token: token,
      new_email: new_email
    } do
      old_email = user.email

      assert {:ok, updated_user, _message} =
               Auth.verify_email_change(token, ClientIP.request_opts(%Plug.Conn{}))

      assert updated_user.email == new_email
      assert updated_user.pending_email == nil
      assert updated_user.email_change_token_hash == nil
      assert %DateTime{} = updated_user.email_change_confirmed_at

      # Verify the confirmation email job was enqueued for both addresses
      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_email_change_confirmations",
          "user_id" => updated_user.id,
          "old_email" => old_email,
          "new_email" => new_email
        }
      )
    end

    test "invalidates all sessions on successful verification", %{user: user, token: token} do
      session = insert(:user_session, user: user)

      assert {:ok, _updated_user, _message} =
               Auth.verify_email_change(token, ClientIP.request_opts(%Plug.Conn{}))

      refute Repo.get(UserSessionSchema, session.id)
    end

    test "disconnects live sockets of revoked sessions after commit", %{user: user, token: token} do
      session = insert(:user_session, user: user)
      Endpoint.subscribe("users_sessions:#{Base.url_encode64(Token.hash_token(session.token))}")

      assert {:ok, _updated_user, _message} =
               Auth.verify_email_change(token, ClientIP.request_opts(%Plug.Conn{}))

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "revokes a reset link mailed to the old address", %{user: user, token: token} do
      reset_token = Token.generate_token()
      {:ok, _user} = UserTokenQueries.set_reset_token(user, reset_token)

      assert {:ok, updated_user, _message} =
               Auth.verify_email_change(token, ClientIP.request_opts(%Plug.Conn{}))

      assert updated_user.reset_token_hash == nil
      assert updated_user.reset_sent_at == nil
      assert {:error, :invalid_token, _message} = PasswordReset.verify_token(reset_token)
    end

    test "a token just inside its 24-hour lifetime still confirms", %{user: user, token: token} do
      set_email_change_sent_at(user, -(24 * 3600 - 60))

      assert {:ok, _user, _message} =
               Auth.verify_email_change(token, ClientIP.request_opts(%Plug.Conn{}))
    end

    test "a confirmed link cannot be used a second time", %{token: token} do
      assert {:ok, _user, _message} =
               Auth.verify_email_change(token, ClientIP.request_opts(%Plug.Conn{}))

      assert {:error, {:invalid_token, _message}} =
               Auth.verify_email_change(token, ClientIP.request_opts(%Plug.Conn{}))
    end

    test "fails with invalid token" do
      assert {:error, {:invalid_token, _message}} =
               Auth.verify_email_change("invalid_token_123", ClientIP.request_opts(%Plug.Conn{}))
    end

    test "fails with expired token", %{user: user, token: token} do
      # Set email_change_sent_at to more than 24 hours ago
      expired_time =
        DateTime.truncate(DateTime.add(DateTime.utc_now(), -25 * 60 * 60, :second), :second)

      user
      |> Changeset.change(%{email_change_sent_at: expired_time})
      |> Repo.update!()

      assert {:error, {:token_expired, _message}} =
               Auth.verify_email_change(token, ClientIP.request_opts(%Plug.Conn{}))
    end
  end

  describe "cancel_email_change/1" do
    setup do
      user = insert(:user)
      new_email = "new.email@example.com"
      token = Token.generate_token()

      {:ok, user_with_pending} =
        UserTokenQueries.request_email_change(user, new_email, token)

      {:ok, user: user_with_pending, new_email: new_email}
    end

    test "successfully cancels pending email change", %{user: user, new_email: new_email} do
      assert user.pending_email == new_email

      assert {:ok, updated_user, _message} = Auth.cancel_email_change(user)

      assert updated_user.pending_email == nil
      assert updated_user.email_change_token_hash == nil
      assert updated_user.email_change_sent_at == nil
    end
  end

  describe "cancel_email_change/1 revokes the link" do
    test "the cancelled link no longer confirms" do
      user = insert(:user)
      token = Token.generate_token()
      {:ok, user} = UserTokenQueries.request_email_change(user, "new.email@example.com", token)

      assert {:ok, _user, _message} = Auth.cancel_email_change(user)

      assert {:error, {:invalid_token, _message}} =
               Auth.verify_email_change(token, ClientIP.request_opts(%Plug.Conn{}))
    end
  end

  describe "email availability check with concurrency" do
    test "prevents race conditions with pessimistic locking" do
      email = "concurrent.test@example.com"

      # Spawn multiple processes trying to claim the same email
      tasks =
        for _i <- 1..5 do
          Task.async(fn ->
            user = insert(:user)

            Auth.request_email_change(
              user,
              email,
              "Password123!",
              ClientIP.request_opts(%Plug.Conn{})
            )
          end)
        end

      results = Task.await_many(tasks)

      # Only one should succeed
      successful =
        Enum.filter(results, fn
          {:ok, _user, _message} -> true
          _other -> false
        end)

      assert length(successful) == 1
    end
  end

  # The link is stored encrypted in the job args; read it back as the worker does.
  defp emailed_link(job, key) do
    {:ok, url} = LinkArg.fetch(job.args, key)
    url
  end

  defp set_email_change_sent_at(user, offset_seconds) do
    sent_at = DateTime.add(DateTime.utc_now(:second), offset_seconds, :second)

    user
    |> Changeset.change(%{email_change_sent_at: sent_at})
    |> Repo.update!()
  end
end
