defmodule Tymeslot.Auth.AuthenticationTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth

  alias Tymeslot.Auth.{Authentication, UserSchema}
  alias Tymeslot.Repo
  alias Tymeslot.Security.{Password, RateLimiter}
  alias Tymeslot.Workers.EmailWorker

  import Tymeslot.Factory

  describe "authenticate_user/3" do
    test "successful authentication returns {:ok, user, message}" do
      password = "ValidPass123!"
      user = insert(:user, password_hash: Password.hash_password(password))

      assert {:ok, returned_user, "Login successful."} =
               Authentication.authenticate_user(user.email, password)

      assert returned_user.id == user.id
    end

    test "successful authentication emits [:tymeslot, :auth, :login_completed] telemetry" do
      password = "ValidPass123!"
      user = insert(:user, password_hash: Password.hash_password(password))

      ref = :telemetry_test.attach_event_handlers(self(), [[:tymeslot, :auth, :login_completed]])

      assert {:ok, _user, _msg} = Authentication.authenticate_user(user.email, password)

      assert_received {[:tymeslot, :auth, :login_completed], ^ref, %{count: 1},
                       %{method: "password"}}
    end

    test "an unverified account with the correct password gets the generic failure" do
      password = "ValidPass123!"
      user = insert(:unverified_user, password_hash: Password.hash_password(password))
      taken = insert(:user, password_hash: Password.hash_password("OtherPass123!"))

      # Anyone can sign up an unverified account for an address, so admitting
      # to it with its password would tell them the address was free.
      assert Authentication.authenticate_user(user.email, password) ==
               Authentication.authenticate_user(taken.email, "WrongPass123!")
    end

    test "an unverified account with the correct password is sent a fresh link, quietly" do
      password = "ValidPass123!"
      user = insert(:unverified_user, password_hash: Password.hash_password(password))

      Authentication.authenticate_user(user.email, password, ip_address: "198.51.100.61")

      assert [job] =
               all_enqueued(
                 worker: EmailWorker,
                 args: %{"action" => "send_email_verification", "user_id" => user.id}
               )

      assert job.args["token_hash"] == Repo.get!(UserSchema, user.id).verification_token
    end

    test "the fresh link is capped per account, and the reply stays the generic failure" do
      password = "ValidPass123!"
      user = insert(:unverified_user, password_hash: Password.hash_password(password))
      for _i <- 1..5, do: RateLimiter.check_verification_user_rate_limit(user.id)

      assert {:error, :invalid_password, message} =
               Authentication.authenticate_user(user.email, password, ip_address: "198.51.100.62")

      assert message == generic_error()
      assert [] = all_enqueued(worker: EmailWorker)
    end

    test "a wrong password on an unverified account sends nothing" do
      user = insert(:unverified_user, password_hash: Password.hash_password("ValidPass123!"))

      Authentication.authenticate_user(user.email, "WrongPass123!", ip_address: "198.51.100.63")

      assert [] = all_enqueued(worker: EmailWorker)
    end

    test "the generic failure points recent sign-ups at their inbox" do
      assert generic_error() ==
               "Invalid email or password. If you signed up recently, check your inbox for the verification link."
    end

    test "unverified user with a wrong password gets the generic error, not 'not verified'" do
      user = insert(:unverified_user, password_hash: Password.hash_password("ValidPass123!"))

      assert {:error, :invalid_password, message} =
               Authentication.authenticate_user(user.email, "WrongPass123!")

      assert message == generic_error()
    end

    test "consistent error messages prevent user enumeration" do
      # Non-existent user
      {:error, _reason, message1} =
        Authentication.authenticate_user("fake@example.com", "password")

      # Existing user wrong password
      user = insert(:user, password_hash: Password.hash_password("RealPass123!"))
      {:error, _reason, message2} = Authentication.authenticate_user(user.email, "WrongPass")

      # Messages must be identical
      assert message1 == message2
    end

    test "validates input to prevent injection attacks" do
      assert {:error, :invalid_input, _message} = Authentication.authenticate_user("", "pass")
      assert {:error, :invalid_input, _message} = Authentication.authenticate_user("email", "")
    end

    test "password over 1024 bytes is rejected before bcrypt runs" do
      # A 1025-byte password must be rejected at validation, not passed to bcrypt
      long_password = String.duplicate("A", 1025)

      assert {:error, :invalid_input, errors} =
               Authentication.authenticate_user("test@example.com", long_password)

      assert errors[:password]
    end

    test "password of 1024 multibyte characters (>1024 bytes) is rejected before bcrypt runs" do
      # 1024 × 4-byte codepoints = 4096 bytes; byte_size check must catch what String.length would miss
      long_password = String.duplicate("𠜎", 1025)

      assert {:error, :invalid_input, errors} =
               Authentication.authenticate_user("test@example.com", long_password)

      assert errors[:password]
    end

    test "nil password returns {:error, :invalid_input, _}" do
      assert {:error, :invalid_input, errors} =
               Authentication.authenticate_user("test@example.com", nil)

      assert errors[:password]
    end

    test "an account without a password gets the generic error, not 'social login'" do
      oauth_user = insert(:user, provider: "google", password_hash: nil)

      assert {:error, :invalid_password, message} =
               Authentication.authenticate_user(oauth_user.email, "any-password")

      assert message == generic_error()
    end

    test "a social-login account is only named as such once its password is proved" do
      password = "ValidPass123!"
      user = insert(:user, provider: "google", password_hash: Password.hash_password(password))

      assert {:error, :invalid_password, _message} =
               Authentication.authenticate_user(user.email, "WrongPass123!")

      assert {:error, :oauth_user, message} =
               Authentication.authenticate_user(user.email, password)

      assert message =~ "social login"
    end
  end

  # What an unknown address gets: every other failure before the password is
  # proved must be indistinguishable from it.
  defp generic_error do
    {:error, :not_found, message} =
      Authentication.authenticate_user(
        "nobody-#{System.unique_integer([:positive])}@example.com",
        "x"
      )

    message
  end
end
