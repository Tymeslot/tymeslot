defmodule Tymeslot.DataLayer.CaseInsensitiveUniqueIndexesTest do
  @moduledoc """
  The users.email and profiles.username unique indexes are case-insensitive
  (functional indexes on lower(...)). App changesets already downcase email and
  constrain usernames to lowercase, so these tests insert structs directly
  (bypassing the changesets) to prove the DB itself rejects case-variant
  duplicates — the guarantee that protects any path skipping the changeset.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :database

  import Tymeslot.Factory

  describe "users.email" do
    test "rejects a case-variant duplicate email at the DB level" do
      insert(:user, email: "Case.Test@Example.com")

      assert_raise Ecto.ConstraintError, ~r/users_email_index/, fn ->
        insert(:user, email: "case.test@example.com")
      end
    end
  end

  describe "profiles.username" do
    test "rejects a case-variant duplicate username at the DB level" do
      insert(:profile, user: insert(:user), username: "Case_User")

      assert_raise Ecto.ConstraintError, ~r/profiles_username_index/, fn ->
        insert(:profile, user: insert(:user), username: "case_user")
      end
    end
  end
end
