defmodule Tymeslot.Auth.EmailChangeTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth

  alias Ecto.Changeset
  alias Tymeslot.Auth
  alias Tymeslot.DatabaseQueries.UserQueries
  alias Tymeslot.DatabaseSchemas.UserSessionSchema
  alias Tymeslot.Security.Token
  alias Tymeslot.Workers.EmailWorker

  import Tymeslot.Factory

  describe "request_email_change/3" do
    setup do
      user = insert(:user)
      {:ok, user: user}
    end

    test "successfully requests email change with valid credentials", %{user: user} do
      new_email = "new.email@example.com"

      assert {:ok, updated_user, message} =
               Auth.request_email_change(user, new_email, "Password123!")

      assert updated_user.pending_email == new_email
      assert updated_user.email_change_token_hash != nil
      assert updated_user.email_change_sent_at != nil
      assert message =~ "Verification email sent"

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

      assert is_binary(verification_job.args["verification_url"])

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

      assert {:error, "Current password is incorrect"} =
               Auth.request_email_change(user, new_email, "wrong_password")
    end

    test "fails with same email as current", %{user: user} do
      assert {:error, "New email must be different from current email"} =
               Auth.request_email_change(user, user.email, "Password123!")
    end

    test "fails with invalid email format", %{user: user} do
      assert {:error, _error_reason} =
               Auth.request_email_change(user, "not-an-email", "Password123!")
    end

    test "fails when email is already taken", %{user: user} do
      other_user = insert(:user)

      assert {:error, "Email address is already in use"} =
               Auth.request_email_change(user, other_user.email, "Password123!")
    end

    test "overwrites pending change when a new one is requested", %{user: user} do
      first_email = "first@example.com"
      second_email = "second@example.com"

      {:ok, user_with_first, _message} = Auth.request_email_change(user, first_email, "Password123!")
      assert user_with_first.pending_email == first_email

      # Request again with a different email; the previous pending state should be overwritten
      {:ok, user_with_second, _message} =
        Auth.request_email_change(user_with_first, second_email, "Password123!")

      assert user_with_second.pending_email == second_email
    end
  end

  describe "verify_email_change/1" do
    setup do
      user = insert(:user)
      new_email = "new.email@example.com"
      token = Token.generate_token()

      {:ok, user_with_pending} =
        UserQueries.request_email_change(user, new_email, token)

      {:ok, user: user_with_pending, token: token, new_email: new_email}
    end

    test "successfully verifies and completes email change", %{
      user: user,
      token: token,
      new_email: new_email
    } do
      old_email = user.email

      assert {:ok, updated_user, message} = Auth.verify_email_change(token)

      assert updated_user.email == new_email
      assert updated_user.pending_email == nil
      assert updated_user.email_change_token_hash == nil
      assert updated_user.email_change_confirmed_at != nil
      assert message =~ "successfully"

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

      assert {:ok, _updated_user, _message} = Auth.verify_email_change(token)

      refute Repo.get(UserSessionSchema, session.id)
    end

    test "fails with invalid token" do
      assert {:error, :invalid_token, message} =
               Auth.verify_email_change("invalid_token_123")

      assert message =~ "Invalid"
    end

    test "fails with expired token", %{user: user, token: token} do
      # Set email_change_sent_at to more than 24 hours ago
      expired_time =
        DateTime.truncate(DateTime.add(DateTime.utc_now(), -25 * 60 * 60, :second), :second)

      user
      |> Changeset.change(%{email_change_sent_at: expired_time})
      |> Repo.update!()

      assert {:error, :token_expired, message} = Auth.verify_email_change(token)
      assert message =~ "expired"
    end
  end

  describe "cancel_email_change/1" do
    setup do
      user = insert(:user)
      new_email = "new.email@example.com"
      token = Token.generate_token()

      {:ok, user_with_pending} =
        UserQueries.request_email_change(user, new_email, token)

      {:ok, user: user_with_pending}
    end

    test "successfully cancels pending email change", %{user: user} do
      assert user.pending_email != nil

      assert {:ok, updated_user, message} = Auth.cancel_email_change(user)

      assert updated_user.pending_email == nil
      assert updated_user.email_change_token_hash == nil
      assert updated_user.email_change_sent_at == nil
      assert message =~ "cancelled"
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
            Auth.request_email_change(user, email, "Password123!")
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
end
