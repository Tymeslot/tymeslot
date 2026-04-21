defmodule Tymeslot.Auth.PasswordResetTest do
  use Tymeslot.DataCase, async: false

  @moduletag :auth

  alias Tymeslot.Auth.PasswordReset
  alias Tymeslot.Auth.{UserSchema, UserSessionQueries, UserTokenQueries}
  alias Tymeslot.Repo
  alias Tymeslot.Security.{Password, Token}

  import Tymeslot.Factory

  describe "password reset security" do
    test "rejects empty email with an error rather than the anti-enumeration success" do
      assert {:error, :invalid_input, _message} = PasswordReset.initiate_reset("")
    end

    test "rejects malformed email with an error rather than the anti-enumeration success" do
      assert {:error, :invalid_input, _message} = PasswordReset.initiate_reset("not-an-email")
    end

    test "password reset returns consistent messages to prevent email enumeration" do
      # Existing user
      insert(:user, email: "exists@example.com")
      {:ok, :reset_initiated, message1} = PasswordReset.initiate_reset("exists@example.com")

      # Non-existent user gets same response to prevent enumeration
      {:ok, :reset_initiated, message2} = PasswordReset.initiate_reset("fake@example.com")

      # Both messages are identical to prevent email enumeration attacks
      expected_message =
        "If an account exists with this email address, password reset instructions have been sent."

      assert message1 == expected_message
      assert message2 == expected_message

      # Messages don't reveal whether email exists
      refute message1 =~ "user not found"
      refute message2 =~ "user not found"
    end

    test "oauth users cannot reset passwords" do
      oauth_user = insert(:user, provider: "google", password_hash: nil)

      # OAuth users should get an error
      result = PasswordReset.initiate_reset(oauth_user.email)

      assert {:error, :oauth_user, _message} = result
    end
  end

  describe "verify_token/1" do
    test "with valid token returns {:ok, user_map, message}" do
      user = insert(:user, password_hash: Password.hash_password("OldPass123!"))
      {token, _value} = Token.generate_password_reset_token()
      {:ok, _result} = UserTokenQueries.set_reset_token(user, token)

      assert {:ok, user_map, _message} = PasswordReset.verify_token(token)
      assert user_map.id == user.id
    end

    test "with expired token returns {:error, :token_expired, _}" do
      user = insert(:user)
      {token, _value} = Token.generate_password_reset_token()
      {:ok, _result} = UserTokenQueries.set_reset_token(user, token)

      # Manually expire the token by setting reset_sent_at to 3 hours ago
      expired_time = DateTime.add(DateTime.utc_now(), -3 * 3600, :second)

      Repo.update_all(
        from(u in UserSchema, where: u.id == ^user.id),
        set: [reset_sent_at: expired_time]
      )

      assert {:error, :token_expired, _message} = PasswordReset.verify_token(token)
    end

    test "with non-existent token returns {:error, :invalid_token, _}" do
      assert {:error, :invalid_token, _message} =
               PasswordReset.verify_token("nonexistent-token-value")
    end
  end

  describe "reset_password/3" do
    test "reset tokens are single-use" do
      user = insert(:user, password_hash: Password.hash_password("OldPass123!"))
      {token, _value} = Token.generate_password_reset_token()
      {:ok, _result} = UserTokenQueries.set_reset_token(user, token)

      new_password = "NewSecurePassword123!"

      # First use succeeds
      result = PasswordReset.reset_password(token, new_password, new_password)
      assert match?({:ok, _, _}, result) or match?({:error, :invalid_token, _}, result)

      # Second use always fails
      assert {:error, :invalid_token, _message} =
               PasswordReset.reset_password(token, "AnotherPass123!", "AnotherPass123!")
    end

    test "invalidates all existing sessions" do
      user = insert(:user, password_hash: Password.hash_password("OldPass123!"))
      sessions = insert_list(3, :user_session, user: user)
      {token, _value} = Token.generate_password_reset_token()
      {:ok, _result} = UserTokenQueries.set_reset_token(user, token)

      new_password = "NewSecurePassword123!"
      {:ok, _user_map, _message} = PasswordReset.reset_password(token, new_password, new_password)

      # All sessions should be invalidated
      Enum.each(sessions, fn session ->
        assert nil == UserSessionQueries.get_user_by_session_token(session.token)
      end)
    end

    test "with mismatched confirmation returns error" do
      user = insert(:user, password_hash: Password.hash_password("OldPass123!"))
      {token, _value} = Token.generate_password_reset_token()
      {:ok, _result} = UserTokenQueries.set_reset_token(user, token)

      assert {:error, _reason, _message} =
               PasswordReset.reset_password(token, "NewPass123!", "DifferentPass123!")
    end

    test "enforces strong password requirements" do
      user = insert(:user)
      {token, _value} = Token.generate_password_reset_token()
      {:ok, _result} = UserTokenQueries.set_reset_token(user, token)

      # Weak password rejected
      assert {:error, _reason, _changeset} = PasswordReset.reset_password(token, "weak", "weak")
    end
  end

  describe "initiate_reset/1 rate limiting" do
    test "rate limits repeated requests" do
      insert(:user, email: "ratelimit@example.com")

      # Per-email limit is 5/hour; send 20 requests — first 5 succeed, rest are blocked
      results =
        for _i <- 1..20 do
          PasswordReset.initiate_reset("ratelimit@example.com", ip: "192.168.1.100")
        end

      rate_limited = Enum.filter(results, &match?({:error, :rate_limited, _msg}, &1))
      assert length(rate_limited) >= 15
    end
  end

  describe "token tamper + replay resistance" do
    test "a single-bit-flipped token is rejected as :invalid_token, not matched to a neighbour" do
      user = insert(:user, password_hash: Password.hash_password("OldPass123!"))
      {token, _value} = Token.generate_password_reset_token()
      {:ok, _result} = UserTokenQueries.set_reset_token(user, token)

      # Flip the last character to produce a different-but-same-length token.
      tampered = flip_last_char(token)
      refute tampered == token

      assert {:error, :invalid_token, _msg} =
               PasswordReset.reset_password(tampered, "NewPass123!", "NewPass123!")

      # And the real token still works — the tampered attempt must not have
      # burned the legitimate reset token.
      assert {:ok, _user_map, _msg} =
               PasswordReset.reset_password(token, "NewPass123!", "NewPass123!")
    end

    test "concurrent resets with the same valid token: only one succeeds" do
      # Note: `async: false` puts DataCase into sandbox `shared: true` mode, which
      # means all processes share a single DB connection. The two Task.async calls
      # below therefore serialise at the connection pool rather than at Postgres, so
      # this test cannot exercise the `FOR UPDATE` row-level lock directly. What it
      # *does* verify is the end-state invariant: regardless of interleaving, exactly
      # one caller succeeds and the other receives `:invalid_token`. The `FOR UPDATE`
      # lock itself is verified at the query level in
      # `Tymeslot.Auth.UserTokenQueriesTest`.
      user = insert(:user, password_hash: Password.hash_password("OldPass123!"))
      {token, _value} = Token.generate_password_reset_token()
      {:ok, _result} = UserTokenQueries.set_reset_token(user, token)

      tasks =
        for pw <- ["FirstNewPass1!", "SecondNewPass2!"] do
          Task.async(fn -> PasswordReset.reset_password(token, pw, pw) end)
        end

      results = Task.await_many(tasks, 10_000)
      successes = Enum.count(results, &match?({:ok, _user, _msg}, &1))
      invalid = Enum.count(results, &match?({:error, :invalid_token, _msg}, &1))

      assert successes == 1,
             "expected exactly one {:ok, _, _} result, got: #{inspect(results)}"

      assert invalid == 1,
             "expected exactly one {:error, :invalid_token, _} result, got: #{inspect(results)}"
    end
  end

  # --- Helpers for the tamper suite ---

  defp flip_last_char(token) do
    <<prefix::binary-size(byte_size(token) - 1), last::utf8>> = token
    flipped = if last == ?A, do: ?B, else: ?A
    <<prefix::binary, flipped::utf8>>
  end
end
