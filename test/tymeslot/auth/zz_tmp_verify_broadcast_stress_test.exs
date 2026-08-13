# Stress reproduction for the flaky assertion in
# test/tymeslot/auth/auth_test.exs:128 — many async modules hammering
# Auth.verify_user_email/1 concurrently, each asserting the supervised
# broadcast arrives.

for n <- 1..16 do
  defmodule :"Elixir.Tymeslot.VerifyBroadcastStress#{n}Test" do
    use Tymeslot.DataCase, async: true

    @moduletag :auth

    alias Tymeslot.Auth
    alias Tymeslot.Auth.UserTokenQueries
    alias Tymeslot.Security.Token

    import Tymeslot.Factory

    for i <- 1..25 do
      test "broadcast arrives #{i}" do
        user = insert(:unverified_user)
        {token, _expiry, _purpose} = Token.generate_email_verification_token(user.id)
        {:ok, _updated} = UserTokenQueries.set_verification_token(user, token)

        Phoenix.PubSub.subscribe(Tymeslot.PubSub, "auth:user_registered")

        assert {:ok, verified_user} = Auth.verify_user_email(token)
        assert verified_user.id == user.id

        user_id = user.id
        assert_receive {:user_registered, %{user: %{id: ^user_id}}}, 500
      end
    end
  end
end
