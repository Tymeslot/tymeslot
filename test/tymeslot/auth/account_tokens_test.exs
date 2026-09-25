defmodule Tymeslot.Auth.AccountTokensTest do
  use Tymeslot.DataCase, async: true

  @moduletag :auth

  alias Ecto.Changeset
  alias Tymeslot.Auth.AccountTokens
  alias Tymeslot.Repo

  # Each purpose's lifetime, pinned where it is enforced: a token issued just
  # inside it resolves, one issued just outside it is rejected as expired.
  @lifetimes [reset: 2 * 3600, verification: 24 * 3600, email_change: 24 * 3600]

  @issued_at_field %{
    reset: :reset_sent_at,
    verification: :verification_sent_at,
    email_change: :email_change_sent_at
  }

  for {purpose, lifetime} <- @lifetimes do
    describe "fetch/3 for #{purpose}" do
      test "resolves a token issued just inside its #{lifetime}s lifetime" do
        {user, token} = issue(unquote(purpose))
        backdate(user, unquote(purpose), -(unquote(lifetime) - 60))

        assert {:ok, found} = AccountTokens.fetch(unquote(purpose), token)
        assert found.id == user.id
      end

      test "rejects a token issued just outside its #{lifetime}s lifetime, naming its user" do
        {user, token} = issue(unquote(purpose))
        backdate(user, unquote(purpose), -(unquote(lifetime) + 60))

        assert {:error, :token_expired, expired_for} =
                 AccountTokens.fetch(unquote(purpose), token)

        assert expired_for.id == user.id
      end

      test "rejects a token that was never issued" do
        assert {:error, :invalid_token} = AccountTokens.fetch(unquote(purpose), "no-such-token")
      end

      test "a newer token replaces the earlier one" do
        {user, old_token} = issue(unquote(purpose))

        {:ok, _user, _new_token} =
          AccountTokens.issue(unquote(purpose), user, issue_attrs(unquote(purpose)))

        assert {:error, :invalid_token} = AccountTokens.fetch(unquote(purpose), old_token)
      end
    end
  end

  describe "consume/3" do
    test "a consumed verification token no longer resolves" do
      {user, token} = issue(:verification)

      assert {:ok, verified} = AccountTokens.consume(:verification, user)
      assert %DateTime{} = verified.verified_at
      assert {:error, :invalid_token} = AccountTokens.fetch(:verification, token)
    end

    test "a consumed reset token no longer resolves" do
      {user, token} = issue(:reset)

      assert {:ok, _user} =
               AccountTokens.consume(:reset, user, %{
                 password: "NewSecurePassword123!",
                 password_confirmation: "NewSecurePassword123!"
               })

      assert {:error, :invalid_token} = AccountTokens.fetch(:reset, token)
    end

    test "a consumed email change token no longer resolves" do
      {user, token} = issue(:email_change)

      assert {:ok, changed} = AccountTokens.consume(:email_change, user)
      assert changed.email == "pending@example.com"
      assert {:error, :invalid_token} = AccountTokens.fetch(:email_change, token)
    end
  end

  defp issue(purpose) do
    user = insert(:user, verified_at: nil)
    {:ok, user, token} = AccountTokens.issue(purpose, user, issue_attrs(purpose))
    {user, token}
  end

  defp issue_attrs(:email_change), do: %{new_email: "pending@example.com"}
  defp issue_attrs(_purpose), do: %{}

  defp backdate(user, purpose, offset_seconds) do
    issued_at = DateTime.add(DateTime.utc_now(:second), offset_seconds, :second)

    user
    |> Changeset.change(%{Map.fetch!(@issued_at_field, purpose) => issued_at})
    |> Repo.update!()
  end
end
