defmodule Tymeslot.DatabaseSchemas.UserSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :schema

  alias Tymeslot.DatabaseSchemas.UserSchema

  describe "security validations" do
    test "enforces strong password requirements" do
      test_cases = [
        {"short", "should be at least 8 character(s)"},
        {"alllowercase", "must contain at least one upper case character"},
        {"ALLUPPERCASE", "must contain at least one lower case character"},
        {"NoNumbers!", "must contain at least one digit"}
      ]

      for {password, expected_error} <- test_cases do
        changeset =
          UserSchema.changeset(%UserSchema{}, %{email: "test@example.com", password: password})

        refute changeset.valid?
        assert expected_error in errors_on(changeset).password
      end
    end

    test "securely hashes passwords during registration" do
      plain_password = "SecurePassword123!"

      attrs = %{
        email: "secure@example.com",
        password: plain_password,
        password_confirmation: plain_password
      }

      changeset = UserSchema.registration_changeset(%UserSchema{}, attrs)

      # Verify password was hashed (different from plain text)
      assert changeset.valid?
      assert changeset.changes.password_hash
      assert changeset.changes.password_hash != plain_password
      assert String.length(changeset.changes.password_hash) > 30
    end

    test "prevents duplicate email registrations" do
      email = "unique@example.com"
      insert(:user, email: email)

      {:error, changeset} =
        %UserSchema{}
        |> UserSchema.registration_changeset(%{
          email: email,
          password: "Password123!",
          password_confirmation: "Password123!"
        })
        |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).email
    end

    test "prevents social provider account hijacking" do
      provider = "google"
      provider_uid = "unique-123"
      insert(:user, provider: provider, provider_uid: provider_uid)

      {:error, changeset} =
        %UserSchema{}
        |> UserSchema.social_registration_changeset(%{
          email: "another@example.com",
          provider: provider,
          provider_uid: provider_uid
        })
        |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).provider
    end
  end
end
