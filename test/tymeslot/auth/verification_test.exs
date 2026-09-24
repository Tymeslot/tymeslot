defmodule Tymeslot.Auth.VerificationTest do
  # async: false — tests use Repo.update_all to manipulate timestamps directly,
  # which requires exclusive sandbox access to avoid interfering with other tests.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Auth.UserTokenQueries
  alias Tymeslot.Auth.Verification
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Repo
  alias Tymeslot.Security.{RateLimiter, Token}
  alias Tymeslot.Test.LogCapture
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.Helpers.ClientIP

  import Tymeslot.Factory

  describe "verify_email_and_maybe_login/2" do
    defp user_with_token(signup_ip) do
      user = insert(:unverified_user, signup_ip: signup_ip)
      token = Token.generate_token()
      {:ok, _user} = UserTokenQueries.set_verification_token(user, token)
      {user, token}
    end

    test "grants auto-login when the link is completed from the signup IP" do
      {user, token} = user_with_token("203.0.113.9")

      assert {:ok, verified, :auto_login} =
               Verification.verify_email_and_maybe_login(token, "203.0.113.9")

      assert verified.id == user.id
      assert verified.verified_at
    end

    test "treats the localhost spellings as one address" do
      {_user, token} = user_with_token("127.0.0.1")

      assert {:ok, _verified, :auto_login} =
               Verification.verify_email_and_maybe_login(token, "::1")
    end

    test "verifies but requires a manual login from any other IP" do
      {user, token} = user_with_token("203.0.113.9")

      assert {:ok, _verified, :manual} =
               Verification.verify_email_and_maybe_login(token, "198.51.100.1")

      assert Repo.reload!(user).verified_at
    end

    test "requires a manual login when no signup IP was recorded" do
      {_user, token} = user_with_token(nil)

      assert {:ok, _verified, :manual} = Verification.verify_email_and_maybe_login(token, nil)
    end

    test "rejects an unknown token" do
      assert {:error, :invalid_token} =
               Verification.verify_email_and_maybe_login("no-such-token", "203.0.113.9")
    end
  end

  describe "verify_user/1 with token" do
    test "verification tokens are single-use" do
      user = insert(:unverified_user)
      token = Token.generate_token()

      {:ok, _result} = UserTokenQueries.set_verification_token(user, token)

      # Use the token
      {:ok, _verified_user} = Verification.verify_user(token)

      # Second use fails
      assert {:error, :invalid_token} = Verification.verify_user(token)
    end

    test "verifying a user emits anonymous [:tymeslot, :auth, :email_verified] telemetry" do
      user = insert(:unverified_user)
      token = Token.generate_token()
      {:ok, _result} = UserTokenQueries.set_verification_token(user, token)

      ref = :telemetry_test.attach_event_handlers(self(), [[:tymeslot, :auth, :email_verified]])

      {:ok, _verified_user} = Verification.verify_user(token)

      assert_received {[:tymeslot, :auth, :email_verified], ^ref, %{count: 1}, %{}}
    end

    test "expired token (>24 hours) returns {:error, :token_expired}" do
      user = insert(:unverified_user)
      token = Token.generate_token()

      {:ok, _result} = UserTokenQueries.set_verification_token(user, token)

      # Manually set verification_sent_at to 25 hours ago to simulate expiry
      expired_time = DateTime.add(DateTime.utc_now(), -25 * 3600, :second)

      Repo.update_all(
        from(u in UserSchema, where: u.id == ^user.id),
        set: [verification_sent_at: expired_time]
      )

      assert {:error, :token_expired} = Verification.verify_user(token)
    end

    test "invalid/non-existent token returns {:error, :invalid_token}" do
      assert {:error, :invalid_token} = Verification.verify_user("nonexistent-token-value")
    end

    test "verifying stamps the token as used and clears it, so reuse fails at lookup" do
      user = insert(:unverified_user)
      token = Token.generate_token()

      {:ok, _result} = UserTokenQueries.set_verification_token(user, token)

      # First use succeeds
      {:ok, _verified_user} = Verification.verify_user(token)

      verified = Repo.reload!(user)
      assert %DateTime{} = verified.verification_token_used_at
      assert is_nil(verified.verification_token)

      # The lookup requires a matching token *and* an unset used_at marker, so a
      # replay is never classified as expired: it is simply an unknown token.
      assert {:error, :invalid_token} = Verification.verify_user(token)
    end
  end

  describe "resend_verification_email_by_email/2" do
    test "every account state gets the same :ok, and only an unverified account is sent mail" do
      unverified = insert(:unverified_user)
      verified = insert(:user)
      unknown = "nobody-#{System.unique_integer([:positive])}@example.com"

      replies =
        for email <- [unverified.email, verified.email, unknown, nil] do
          Verification.resend_verification_email_by_email(email, ClientIP.get(%Plug.Conn{}))
        end

      assert replies == [:ok, :ok, :ok, :ok]

      assert [job] = all_enqueued(worker: EmailWorker)
      assert job.args["user_id"] == unverified.id
    end

    test "a verified account's stored token is left alone" do
      verified = insert(:user)

      assert :ok =
               Verification.resend_verification_email_by_email(
                 verified.email,
                 ClientIP.get(%Plug.Conn{})
               )

      assert Repo.get!(UserSchema, verified.id).verification_token ==
               verified.verification_token
    end

    test "an account at its per-user cap is answered :ok and sent nothing" do
      user = insert(:unverified_user)

      for _i <- 1..5 do
        RateLimiter.check_verification_rate_limit(user.id, "198.51.100.77")
      end

      assert :ok =
               Verification.resend_verification_email_by_email(
                 user.email,
                 ClientIP.get(%Plug.Conn{})
               )

      assert [] = all_enqueued(worker: EmailWorker)
    end

    test "the address bucket is charged before the lookup, whatever the address" do
      conn = ClientIP.get(%Plug.Conn{remote_ip: {198, 51, 100, 78}})

      # Five resends for addresses with no account still use up the budget...
      for i <- 1..5 do
        assert :ok =
                 Verification.resend_verification_email_by_email(
                   "unknown-#{i}@example.com",
                   conn
                 )
      end

      # ...so a real unverified account is refused from that address too.
      user = insert(:unverified_user)

      assert {:error, :rate_limited, message} =
               Verification.resend_verification_email_by_email(user.email, conn)

      assert message =~ "verification emails"
      assert [] = all_enqueued(worker: EmailWorker)
    end

    test "a resend within the dedup window rotates the token and updates the queued job" do
      user = insert(:unverified_user)

      # Simulate signup: the first token is stored and its email is already queued.
      original_token = Token.generate_token()
      {:ok, _user} = UserTokenQueries.set_verification_token(user, original_token)

      assert {:ok, :scheduled} =
               EmailScheduler.schedule_email_verification(
                 user.id,
                 "https://example.com/verify",
                 Token.hash_token(original_token)
               )

      # The user hammers "resend" while that first email is still in the dedup window.
      # The token is rotated unconditionally; the scheduler replaces the queued job's
      # args with the new URL so job payload and DB token remain in lock-step.
      assert :ok =
               Verification.resend_verification_email_by_email(
                 user.email,
                 ClientIP.get(%Plug.Conn{})
               )

      # The original token is now invalid — a fresh token was persisted.
      assert {:error, :invalid_token} = Verification.verify_user(original_token)

      # The single queued job now carries the rotated hash, matching the stored token,
      # so the worker's staleness guard will deliver (not discard) it — the new link
      # is genuinely deliverable end to end.
      updated = Repo.get!(UserSchema, user.id)
      assert [job] = all_enqueued(worker: EmailWorker)
      assert job.args["token_hash"] == updated.verification_token
    end

    test "a resend with no email in flight rotates the token and sends a fresh link" do
      user = insert(:unverified_user)

      # An older, still-stored token with no queued email (its delivery never happened).
      stale_token = Token.generate_token()
      {:ok, _user} = UserTokenQueries.set_verification_token(user, stale_token)

      assert :ok =
               Verification.resend_verification_email_by_email(
                 user.email,
                 ClientIP.get(%Plug.Conn{})
               )

      # A genuinely new email is sent, so the token is rotated; the stale token no
      # longer verifies and the fresh raw token lives only in the new email link.
      assert {:error, :invalid_token} = Verification.verify_user(stale_token)
    end
  end

  describe "token tamper resistance" do
    test "a single-bit-flipped token is rejected as :invalid_token, not matched to a neighbour" do
      user = insert(:unverified_user)
      token = Token.generate_token()
      {:ok, _result} = UserTokenQueries.set_verification_token(user, token)

      # Flip the last character of the base64url token.
      tampered = flip_last_char(token)
      refute tampered == token

      assert {:error, :invalid_token} = Verification.verify_user(tampered)

      # The real token still verifies the user — the tampered attempt must not
      # have consumed the legitimate token.
      assert {:ok, verified_user} = Verification.verify_user(token)
      assert verified_user.verified_at
    end
  end

  describe "verify_user/1 never logs the raw token" do
    test "an expired token's audit entry identifies the user, never the token" do
      user = insert(:unverified_user)
      token = Token.generate_token()
      {:ok, _result} = UserTokenQueries.set_verification_token(user, token)

      expired_time = DateTime.add(DateTime.utc_now(), -25 * 3600, :second)

      Repo.update_all(
        from(u in UserSchema, where: u.id == ^user.id),
        set: [verification_sent_at: expired_time]
      )

      LogCapture.with_capture([logger_level: :info], fn ->
        assert {:error, :token_expired} = Verification.verify_user(token)
      end)

      assert_receive {:captured_log, %{meta: %{event: "email_verification_failure"} = meta}}
      assert meta[:identifier_masked] == user.id
      refute inspect(meta) =~ token
    end

    test "an invalid token's audit entry never carries the raw token" do
      unknown_token = "unknown-token-value-not-in-the-database"

      LogCapture.with_capture([logger_level: :info], fn ->
        assert {:error, :invalid_token} = Verification.verify_user(unknown_token)
      end)

      assert_receive {:captured_log, %{meta: meta}}
      refute inspect(meta) =~ unknown_token
    end
  end

  # --- Helpers for the tamper suite ---

  defp flip_last_char(token) do
    prefix_size = byte_size(token) - 1
    <<prefix::binary-size(^prefix_size), last::utf8>> = token
    flipped = if last == ?A, do: ?B, else: ?A
    <<prefix::binary, flipped::utf8>>
  end
end
