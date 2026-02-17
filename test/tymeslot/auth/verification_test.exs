defmodule Tymeslot.Auth.VerificationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :auth

  alias Tymeslot.Auth.Verification
  alias Tymeslot.DatabaseQueries.UserQueries
  alias Tymeslot.Security.Token

  import Tymeslot.Factory

  describe "email verification security" do
    test "verification tokens are single-use" do
      user = insert(:unverified_user)
      {token, _hashed_token, _expires_at} = Token.generate_email_verification_token(user.id)

      {:ok, _result} =
        UserQueries.update_user(user, %{
          verification_token: token,
          verification_sent_at: DateTime.utc_now()
        })

      # Use the token
      {:ok, _verified_user} = Verification.verify_user(token)

      # Second use fails
      assert {:error, :invalid_token} = Verification.verify_user(token)
    end
  end
end
