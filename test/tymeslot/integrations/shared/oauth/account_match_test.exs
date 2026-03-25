defmodule Tymeslot.Integrations.Common.OAuth.AccountMatchTest do
  use Tymeslot.DataCase, async: true
  @moduletag :unit
  @moduletag :integrations

  alias Tymeslot.Integrations.Common.OAuth.AccountMatch

  describe "verify_account_match/3" do
    test "allows update when both account IDs are nil" do
      existing = %{id: 1, provider_account_id: nil}
      update_fn = fn -> {:ok, :updated} end

      assert {:ok, :updated} = AccountMatch.verify_account_match(existing, nil, update_fn)
    end

    test "allows update when existing is nil and new is present" do
      existing = %{id: 1, provider_account_id: nil}
      update_fn = fn -> {:ok, :updated} end

      assert {:ok, :updated} =
               AccountMatch.verify_account_match(existing, "new-account-id", update_fn)
    end

    test "returns error when existing has account but new is nil" do
      existing = %{id: 1, provider_account_id: "existing-account-id"}

      update_fn = fn -> {:ok, :should_not_be_called} end

      assert {:error, message} = AccountMatch.verify_account_match(existing, nil, update_fn)
      assert message =~ "Could not verify your account identity"
    end

    test "allows update when both present and matching" do
      existing = %{id: 1, provider_account_id: "same-account-id"}
      update_fn = fn -> {:ok, :updated} end

      assert {:ok, :updated} =
               AccountMatch.verify_account_match(existing, "same-account-id", update_fn)
    end

    test "returns error when both present but mismatching" do
      existing = %{id: 1, provider_account_id: "account-a"}
      update_fn = fn -> {:ok, :should_not_be_called} end

      assert {:error, message} =
               AccountMatch.verify_account_match(existing, "account-b", update_fn)

      assert message =~ "different account"
    end
  end

  describe "create_with_race_protection/3" do
    test "returns success when create succeeds" do
      create_fn = fn -> {:ok, %{id: 1}} end
      lookup_fn = fn -> {:ok, %{id: 2}} end
      update_fn = fn _existing -> {:ok, %{id: 2}} end

      assert {:ok, %{id: 1}} =
               AccountMatch.create_with_race_protection(create_fn, lookup_fn, update_fn)
    end

    test "returns changeset error for non-unique constraint failures" do
      changeset = %Ecto.Changeset{
        errors: [name: {"can't be blank", [validation: :required]}],
        valid?: false
      }

      create_fn = fn -> {:error, changeset} end
      lookup_fn = fn -> {:ok, %{id: 2}} end
      update_fn = fn _existing -> {:ok, %{id: 2}} end

      assert {:error, ^changeset} =
               AccountMatch.create_with_race_protection(create_fn, lookup_fn, update_fn)
    end

    test "falls back to lookup + update on unique account violation" do
      changeset = %Ecto.Changeset{
        errors: [
          user_id:
            {"already exists",
             [constraint: :unique, constraint_name: "unique_active_calendar_account_per_user"]}
        ],
        valid?: false
      }

      create_fn = fn -> {:error, changeset} end
      lookup_fn = fn -> {:ok, %{id: 42}} end
      update_fn = fn existing -> {:ok, %{id: existing.id, updated: true}} end

      assert {:ok, %{id: 42, updated: true}} =
               AccountMatch.create_with_race_protection(create_fn, lookup_fn, update_fn)
    end

    test "returns original error when unique violation but lookup finds nothing" do
      changeset = %Ecto.Changeset{
        errors: [
          user_id:
            {"already exists",
             [constraint: :unique, constraint_name: "unique_active_video_account_per_user"]}
        ],
        valid?: false
      }

      create_fn = fn -> {:error, changeset} end
      lookup_fn = fn -> {:error, :not_found} end
      update_fn = fn _existing -> {:ok, :should_not_be_called} end

      assert {:error, ^changeset} =
               AccountMatch.create_with_race_protection(create_fn, lookup_fn, update_fn)
    end
  end

  describe "unique_account_violation?/1" do
    test "returns true for calendar account constraint" do
      changeset = %Ecto.Changeset{
        errors: [
          user_id:
            {"already exists",
             [constraint: :unique, constraint_name: "unique_active_calendar_account_per_user"]}
        ],
        valid?: false
      }

      assert AccountMatch.unique_account_violation?(changeset)
    end

    test "returns true for video account constraint" do
      changeset = %Ecto.Changeset{
        errors: [
          user_id:
            {"already exists",
             [constraint: :unique, constraint_name: "unique_active_video_account_per_user"]}
        ],
        valid?: false
      }

      assert AccountMatch.unique_account_violation?(changeset)
    end

    test "returns false for other constraint errors" do
      changeset = %Ecto.Changeset{
        errors: [
          email:
            {"has already been taken",
             [constraint: :unique, constraint_name: "users_email_index"]}
        ],
        valid?: false
      }

      refute AccountMatch.unique_account_violation?(changeset)
    end

    test "returns false for non-constraint errors" do
      changeset = %Ecto.Changeset{
        errors: [name: {"can't be blank", [validation: :required]}],
        valid?: false
      }

      refute AccountMatch.unique_account_violation?(changeset)
    end

    test "returns false for empty errors" do
      changeset = %Ecto.Changeset{errors: [], valid?: true}

      refute AccountMatch.unique_account_violation?(changeset)
    end
  end
end
