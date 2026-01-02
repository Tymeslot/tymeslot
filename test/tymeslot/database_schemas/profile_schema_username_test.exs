defmodule Tymeslot.Database.ProfileSchemaUsernameTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :schema

  alias Tymeslot.DatabaseSchemas.ProfileSchema

  describe "username validation" do
    test "accepts valid usernames" do
      valid_usernames = [
        "john123",
        "mary-jane",
        "user2025",
        "a12",
        "123abc",
        "my-awesome-username",
        "user_name"
      ]

      for username <- valid_usernames do
        user = insert(:user)

        changeset =
          ProfileSchema.changeset(%ProfileSchema{}, %{
            user_id: user.id,
            username: username,
            timezone: "Europe/Kyiv"
          })

        assert changeset.valid?, "Username '#{username}' should be valid"
      end
    end

    test "rejects invalid usernames" do
      invalid_usernames = [
        {"ab", "should be at least 3 character(s)"},
        {"a" <> String.duplicate("b", 30), "should be at most 30 character(s)"},
        {"John123",
         "must be 3-30 characters long, start with a letter or number, and contain only lowercase letters, numbers, underscores, and hyphens"},
        {"user@name",
         "must be 3-30 characters long, start with a letter or number, and contain only lowercase letters, numbers, underscores, and hyphens"},
        {"-username",
         "must be 3-30 characters long, start with a letter or number, and contain only lowercase letters, numbers, underscores, and hyphens"},
        {"user name",
         "must be 3-30 characters long, start with a letter or number, and contain only lowercase letters, numbers, underscores, and hyphens"},
        {"user.name",
         "must be 3-30 characters long, start with a letter or number, and contain only lowercase letters, numbers, underscores, and hyphens"}
      ]

      for {username, expected_error} <- invalid_usernames do
        changeset =
          ProfileSchema.changeset(%ProfileSchema{}, %{username: username, timezone: "Europe/Kyiv"})

        refute changeset.valid?, "Username '#{username}' should be invalid"
        assert expected_error in errors_on(changeset).username
      end
    end

    test "rejects reserved usernames" do
      reserved = [
        "admin",
        "api",
        "app",
        "auth",
        "blog",
        "dashboard",
        "dev",
        "docs",
        "help",
        "home",
        "login",
        "logout",
        "meeting",
        "meetings",
        "profile",
        "register",
        "schedule",
        "settings",
        "signup",
        "static",
        "support",
        "test",
        "user",
        "users",
        "www",
        "healthcheck",
        "assets",
        "images",
        "css",
        "js",
        "fonts",
        "about",
        "contact",
        "privacy",
        "terms"
      ]

      for username <- reserved do
        changeset =
          ProfileSchema.changeset(%ProfileSchema{}, %{username: username, timezone: "Europe/Kyiv"})

        refute changeset.valid?, "Username '#{username}' should be reserved"
        assert "is reserved" in errors_on(changeset).username
      end
    end

    test "username uniqueness constraint" do
      user = insert(:user)
      attrs = %{user_id: user.id, username: "testuser", timezone: "Europe/Kyiv"}
      changeset = ProfileSchema.changeset(%ProfileSchema{}, attrs)

      # The unique constraint will be tested at the database level
      assert changeset.valid?

      assert Enum.any?(changeset.constraints, fn c ->
               c.type == :unique && c.field == :username
             end)
    end

    test "username is optional" do
      user = insert(:user)

      changeset =
        ProfileSchema.changeset(%ProfileSchema{}, %{user_id: user.id, timezone: "Europe/Kyiv"})

      assert changeset.valid?
    end
  end
end
