defmodule Tymeslot.Auth.VerificationTest do
  # async: false — tests use Repo.update_all to manipulate timestamps directly,
  # which requires exclusive sandbox access to avoid interfering with other tests.
  use Tymeslot.DataCase, async: false

  @moduletag :auth

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Auth.UserTokenQueries
  alias Tymeslot.Auth.Verification
  alias Tymeslot.Repo
  alias Tymeslot.Security.Token

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
  end
end
