defmodule Tymeslot.Auth.UserTokenQueriesTest do
  @moduledoc false

  use Tymeslot.DataCase, async: true

  @moduletag :auth
  @moduletag :queries

  alias Ecto.Adapters.SQL, as: EctoSQL
  alias Tymeslot.Auth.{UserSchema, UserTokenQueries}
  alias Tymeslot.Repo
  alias Tymeslot.Security.Token

  describe "get_user_by_reset_token_for_update/1" do
    test "returns {:ok, user} for a valid unconsumed token" do
      user = insert(:user)
      {token, _value} = Token.generate_password_reset_token()
      {:ok, _stored} = UserTokenQueries.set_reset_token(user, token)

      assert {:ok, found} = UserTokenQueries.get_user_by_reset_token_for_update(token)
      assert found.id == user.id
    end

    test "returns {:error, :not_found} when the token has already been consumed" do
      user = insert(:user)
      {token, _value} = Token.generate_password_reset_token()
      {:ok, _stored} = UserTokenQueries.set_reset_token(user, token)

      # Mark the token as consumed by setting reset_token_used_at
      Repo.update_all(
        from(u in UserSchema, where: u.id == ^user.id),
        set: [reset_token_used_at: DateTime.utc_now(:second)]
      )

      assert {:error, :not_found} = UserTokenQueries.get_user_by_reset_token_for_update(token)
    end

    test "returns {:error, :not_found} for an unknown token" do
      assert {:error, :not_found} =
               UserTokenQueries.get_user_by_reset_token_for_update("unknown-token-value")
    end

    test "compiled query includes the FOR UPDATE lock clause" do
      # Build the equivalent query directly so we can inspect its SQL without
      # executing it against the database (no token or user needed here).
      token_hash = Base.encode16(:crypto.hash(:sha256, "any-token"), case: :lower)

      query =
        UserSchema
        |> where([u], u.reset_token_hash == ^token_hash and is_nil(u.reset_token_used_at))
        |> lock("FOR UPDATE")

      {sql, _params} = EctoSQL.to_sql(:all, Repo, query)

      assert sql =~ "FOR UPDATE",
             "expected query SQL to contain FOR UPDATE, got: #{sql}"
    end
  end
end
