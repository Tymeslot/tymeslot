defmodule Tymeslot.Auth.PasswordResetTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth

  alias Tymeslot.Auth
  alias Tymeslot.Auth.PasswordReset
  alias Tymeslot.Auth.{UserSchema, UserSessionQueries, UserTokenQueries}
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Repo
  alias Tymeslot.Security.{Password, Token}
  alias Tymeslot.Test.LogCapture
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.Endpoint

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

  describe "initiate_reset/1 token rotation" do
    test "a duplicate request within the dedup window rotates the token and updates the queued job" do
      user = insert(:user, password_hash: Password.hash_password("OldPass123!"))

      # Simulate the first request: store the reset token and queue its email.
      original_token = Token.generate_token()
      {:ok, _result} = UserTokenQueries.set_reset_token(user, original_token)

      assert {:ok, :scheduled} =
               EmailScheduler.schedule_password_reset(
                 user.id,
                 "https://example.com/reset",
                 Token.hash_token(original_token)
               )

      # A second request arrives while that first email is still within the dedup window.
      # The token is rotated unconditionally; the scheduler replaces the queued job's
      # args with the new URL so job payload and DB token remain in lock-step.
      assert {:ok, :reset_initiated, _message} = PasswordReset.initiate_reset(user.email)

      # The original token is now invalid — a fresh token was persisted.
      assert {:error, :invalid_token, _message} = PasswordReset.verify_token(original_token)

      # The single queued job now carries the rotated hash, matching the stored token,
      # so the worker's staleness guard will deliver (not discard) it — the new link
      # is genuinely deliverable end to end.
      updated = Repo.get!(UserSchema, user.id)
      assert [job] = all_enqueued(worker: EmailWorker)
      assert job.args["token_hash"] == updated.reset_token_hash
    end
  end

  describe "verify_token/1" do
    test "with valid token returns the user as a schema struct" do
      user = insert(:user, password_hash: Password.hash_password("OldPass123!"))
      token = Token.generate_token()
      {:ok, _result} = UserTokenQueries.set_reset_token(user, token)

      # A struct, not a bare map: the schema's `redact: true` keeps secrets
      # out of anything that inspects it.
      assert {:ok, %UserSchema{id: user_id}, _message} = PasswordReset.verify_token(token)
      assert user_id == user.id
    end

    test "a token issued just inside its two-hour lifetime is still valid" do
      user = insert(:user)
      token = Token.generate_token()
      {:ok, _result} = UserTokenQueries.set_reset_token(user, token)
      set_reset_sent_at(user, -(2 * 3600 - 60))

      assert {:ok, _user, _message} = PasswordReset.verify_token(token)
    end

    test "a token just past its two-hour lifetime has expired" do
      user = insert(:user)
      token = Token.generate_token()
      {:ok, _result} = UserTokenQueries.set_reset_token(user, token)
      set_reset_sent_at(user, -(2 * 3600 + 60))

      assert {:error, :token_expired, _message} = PasswordReset.verify_token(token)
    end

    test "with expired token returns {:error, :token_expired, _}" do
      user = insert(:user)
      token = Token.generate_token()
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
      token = Token.generate_token()
      {:ok, _result} = UserTokenQueries.set_reset_token(user, token)

      new_password = "NewSecurePassword123!"

      # First use succeeds
      assert {:ok, _user_map, _message} =
               PasswordReset.reset_password(token, new_password, new_password)

      # Second use always fails
      assert {:error, :invalid_token, _message} =
               PasswordReset.reset_password(token, "AnotherPass123!", "AnotherPass123!")
    end

    test "returns the user struct without the plaintext password" do
      user = insert(:user, password_hash: Password.hash_password("OldPass123!"))
      token = Token.generate_token()
      {:ok, _result} = UserTokenQueries.set_reset_token(user, token)

      assert {:ok, %UserSchema{} = updated, _message} =
               PasswordReset.reset_password(
                 token,
                 "NewSecurePassword123!",
                 "NewSecurePassword123!"
               )

      assert updated.id == user.id
      assert updated.password == nil
      assert updated.password_confirmation == nil
      assert Password.verify_password("NewSecurePassword123!", updated.password_hash)
    end

    # Someone who knew the old password requests an email change to an address
    # they control. The owner notices and resets the password to lock them out;
    # the pending change must die with the old credentials, or the attacker
    # could still confirm it and take the account over.
    test "revokes a pending email change, so its link can no longer be confirmed" do
      user = insert(:user, password_hash: Password.hash_password("Password123!"))

      change_token = Token.generate_token()

      {:ok, pending_user} =
        UserTokenQueries.request_email_change(user, "attacker@example.com", change_token)

      reset_token = Token.generate_token()
      {:ok, _result} = UserTokenQueries.set_reset_token(pending_user, reset_token)

      assert {:ok, _user, _message} =
               PasswordReset.reset_password(
                 reset_token,
                 "NewSecurePassword123!",
                 "NewSecurePassword123!"
               )

      reloaded = Repo.get!(UserSchema, user.id)
      assert reloaded.pending_email == nil
      assert reloaded.email_change_token_hash == nil
      assert reloaded.email_change_sent_at == nil

      assert {:error, {:invalid_token, _message}} = Auth.verify_email_change(change_token)
      assert Repo.get!(UserSchema, user.id).email == user.email
    end

    test "records a password_change audit entry carrying the request context" do
      user = insert(:user, password_hash: Password.hash_password("OldPass123!"))
      token = Token.generate_token()
      {:ok, _result} = UserTokenQueries.set_reset_token(user, token)

      # SecurityLogger emits at :info; config/test.exs pins the primary level to
      # :warning, so it has to come down for the duration. Safe here: the module
      # is async: false.
      LogCapture.with_capture([logger_level: :info], fn ->
        assert {:ok, _user_map, _message} =
                 PasswordReset.reset_password(
                   token,
                   "NewSecurePassword123!",
                   "NewSecurePassword123!",
                   ip: "203.0.113.11",
                   user_agent: "curl/8.0"
                 )
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "password_change"} = meta}}
      assert meta.user_id == user.id
      assert meta.ip_address == "203.0.113.11"
      assert meta.user_agent == "curl/8.0"
    end

    test "invalidates all existing sessions and disconnects their live sockets" do
      user = insert(:user, password_hash: Password.hash_password("OldPass123!"))
      sessions = insert_list(3, :user_session, user: user)

      Enum.each(sessions, fn session ->
        Endpoint.subscribe("users_sessions:#{Base.url_encode64(Token.hash_token(session.token))}")
      end)

      token = Token.generate_token()
      {:ok, _result} = UserTokenQueries.set_reset_token(user, token)

      new_password = "NewSecurePassword123!"
      {:ok, _user_map, _message} = PasswordReset.reset_password(token, new_password, new_password)

      # All sessions should be invalidated and their live sockets disconnected
      Enum.each(sessions, fn session ->
        assert nil == UserSessionQueries.get_user_by_session_token(session.token)
        assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      end)
    end

    test "with mismatched confirmation returns error" do
      user = insert(:user, password_hash: Password.hash_password("OldPass123!"))
      token = Token.generate_token()
      {:ok, _result} = UserTokenQueries.set_reset_token(user, token)

      assert {:error, _reason, _message} =
               PasswordReset.reset_password(token, "NewPass123!", "DifferentPass123!")
    end

    test "enforces strong password requirements" do
      user = insert(:user)
      token = Token.generate_token()
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

    test "records a rate-limit audit entry naming the account and origin" do
      insert(:user, email: "ratelimit-audit@example.com")

      for _i <- 1..5 do
        PasswordReset.initiate_reset("ratelimit-audit@example.com", ip: "192.168.1.101")
      end

      # SecurityLogger emits at :info; config/test.exs pins the primary level
      # to :warning, so lower it for the duration of the call.
      LogCapture.with_capture([logger_level: :info], fn ->
        assert {:error, :rate_limited, _message} =
                 PasswordReset.initiate_reset("ratelimit-audit@example.com", ip: "192.168.1.101")
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "rate_limit_violation"} = meta}}

      assert meta.limit_type == "password_reset"
      assert meta.email_masked == "r***@example.com"
      assert meta.ip_address == "192.168.1.101"
      refute inspect(meta) =~ "ratelimit-audit@example.com"
    end
  end

  describe "token tamper + replay resistance" do
    test "a single-bit-flipped token is rejected as :invalid_token, not matched to a neighbour" do
      user = insert(:user, password_hash: Password.hash_password("OldPass123!"))
      token = Token.generate_token()
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
      token = Token.generate_token()
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
    prefix_size = byte_size(token) - 1
    <<prefix::binary-size(^prefix_size), last::utf8>> = token
    flipped = if last == ?A, do: ?B, else: ?A
    <<prefix::binary, flipped::utf8>>
  end

  defp set_reset_sent_at(user, offset_seconds) do
    sent_at = DateTime.add(DateTime.utc_now(:second), offset_seconds, :second)

    Repo.update_all(from(u in UserSchema, where: u.id == ^user.id), set: [reset_sent_at: sent_at])
  end
end
