defmodule Tymeslot.Auth.UserSessionSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :schema
  @moduletag :auth

  import Tymeslot.Factory

  alias Tymeslot.Auth.UserSessionSchema

  describe "changeset/2" do
    test "valid with required fields" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        token: "session_token_abc123",
        expires_at: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
      }

      changeset = UserSessionSchema.changeset(%UserSessionSchema{}, attrs)
      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = UserSessionSchema.changeset(%UserSessionSchema{}, %{})
      refute changeset.valid?

      assert %{
               user_id: ["can't be blank"],
               token: ["can't be blank"],
               expires_at: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "unique constraint on token" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        token: "unique_token_xyz",
        expires_at: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
      }

      {:ok, _session} =
        %UserSessionSchema{}
        |> UserSessionSchema.changeset(attrs)
        |> Repo.insert()

      user2 = insert(:user)

      {:error, changeset} =
        %UserSessionSchema{}
        |> UserSessionSchema.changeset(%{attrs | user_id: user2.id})
        |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).token
    end
  end
end
