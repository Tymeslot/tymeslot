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
  alias Tymeslot.Security.Token
  alias Tymeslot.Workers.EmailWorker

  import Tymeslot.Factory

  describe "verify_user/1 with token" do
    test "verification tokens are single-use" do
      user = insert(:unverified_user)
      {token, _expiry, _purpose} = Token.generate_email_verification_token(user.id)

      {:ok, _result} = UserTokenQueries.set_verification_token(user, token)

      # Use the token
      {:ok, _verified_user} = Verification.verify_user(token)

      # Second use fails
      assert {:error, :invalid_token} = Verification.verify_user(token)
    end

    test "verifying a user emits anonymous [:tymeslot, :auth, :email_verified] telemetry" do
      user = insert(:unverified_user)
      {token, _expiry, _purpose} = Token.generate_email_verification_token(user.id)
      {:ok, _result} = UserTokenQueries.set_verification_token(user, token)

      ref = :telemetry_test.attach_event_handlers(self(), [[:tymeslot, :auth, :email_verified]])

      {:ok, _verified_user} = Verification.verify_user(token)

      assert_received {[:tymeslot, :auth, :email_verified], ^ref, %{count: 1}, %{}}
    end

    test "expired token (>24 hours) returns {:error, :token_expired}" do
      user = insert(:unverified_user)
      {token, _expiry, _purpose} = Token.generate_email_verification_token(user.id)

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

    test "already-verified user token is rejected (verification_token_used_at set)" do
      user = insert(:unverified_user)
      {token, _expiry, _purpose} = Token.generate_email_verification_token(user.id)

      {:ok, _result} = UserTokenQueries.set_verification_token(user, token)

      # First use succeeds
      {:ok, _verified_user} = Verification.verify_user(token)

      # Second use fails — the token is cleared from the DB after first use,
      # so the lookup returns :invalid_token (not :token_expired)
      assert {:error, :invalid_token} = Verification.verify_user(token)
    end
  end

  describe "verify_user/1 with user_id" do
    test "directly verifies user with integer user_id" do
      user = insert(:unverified_user)
      assert is_nil(user.verified_at)

      {:ok, verified_user} = Verification.verify_user(user.id)
      assert verified_user.verified_at != nil
    end
  end

  describe "resend_verification_email_by_email/2" do
    test "returns error for non-existent email" do
      result =
        Verification.resend_verification_email_by_email("nonexistent@example.com", %Plug.Conn{})

      assert {:error, :user_not_found} = result
    end

    test "a resend within the dedup window rotates the token and updates the queued job" do
      user = insert(:unverified_user)

      # Simulate signup: the first token is stored and its email is already queued.
      {original_token, _expiry, _purpose} = Token.generate_email_verification_token(user.id)
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
      assert {:ok, _user} =
               Verification.resend_verification_email_by_email(user.email, %Plug.Conn{})

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
      {stale_token, _expiry, _purpose} = Token.generate_email_verification_token(user.id)
      {:ok, _user} = UserTokenQueries.set_verification_token(user, stale_token)

      assert {:ok, _user} =
               Verification.resend_verification_email_by_email(user.email, %Plug.Conn{})

      # A genuinely new email is sent, so the token is rotated; the stale token no
      # longer verifies and the fresh raw token lives only in the new email link.
      assert {:error, :invalid_token} = Verification.verify_user(stale_token)
    end
  end

  describe "token tamper resistance" do
    test "a single-bit-flipped token is rejected as :invalid_token, not matched to a neighbour" do
      user = insert(:unverified_user)
      {token, _expiry, _purpose} = Token.generate_email_verification_token(user.id)
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

  # --- Helpers for the tamper suite ---

  defp flip_last_char(token) do
    prefix_size = byte_size(token) - 1
    <<prefix::binary-size(^prefix_size), last::utf8>> = token
    flipped = if last == ?A, do: ?B, else: ?A
    <<prefix::binary, flipped::utf8>>
  end
end
