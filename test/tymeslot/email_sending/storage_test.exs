defmodule Tymeslot.EmailSending.StorageTest do
  @moduledoc "Verifies SMTP credential rotation and database ownership invariants."

  use Tymeslot.DataCase, async: true

  @moduletag :emails
  @moduletag :integration

  alias Tymeslot.EmailSending.UserSmtpSettingsSchema
  alias Tymeslot.Security.{CredentialReencryption, Encryption}
  alias Tymeslot.Test.LegacyCiphertext

  test "the rotation sweep migrates both SMTP secrets and can be resumed" do
    settings = insert_settings(insert(:user))

    assert {:ok, %{tables: %{"user_smtp_settings" => stats}}} = CredentialReencryption.run()
    assert stats.migrated_values == 2

    migrated = Repo.get!(UserSmtpSettingsSchema, settings.id)
    assert Encryption.current?(migrated.username_encrypted)
    assert Encryption.current?(migrated.password_encrypted)
    assert Encryption.decrypt(migrated.username_encrypted) == "legacy-smtp-user"
    assert Encryption.decrypt(migrated.password_encrypted) == "legacy-smtp-password"

    assert {:ok, %{tables: %{"user_smtp_settings" => %{migrated_values: 0}}}} =
             CredentialReencryption.run()
  end

  test "the database refuses activation without test evidence" do
    user = insert(:user)

    assert_raise Ecto.ConstraintError, ~r/user_smtp_settings_activation/, fn ->
      insert_settings(user, enabled: true)
    end
  end

  test "the database refuses two identities for the same user" do
    user = insert(:user)
    insert_settings(user)

    assert_raise Ecto.ConstraintError, ~r/user_smtp_settings_user_id_index/, fn ->
      insert_settings(user)
    end
  end

  test "account deletion removes the settings and both encrypted credentials" do
    user = insert(:user)
    settings = insert_settings(user)
    Repo.delete!(user)
    assert Repo.get(UserSmtpSettingsSchema, settings.id) == nil
  end

  defp insert_settings(user, overrides \\ []) do
    %UserSmtpSettingsSchema{
      user_id: user.id,
      host: "smtp.example.com",
      port: 587,
      security: :starttls,
      username_encrypted: LegacyCiphertext.encrypt("legacy-smtp-user"),
      password_encrypted: LegacyCiphertext.encrypt("legacy-smtp-password"),
      from_address: "bookings@example.com",
      from_name: "Bookings"
    }
    |> struct!(overrides)
    |> Repo.insert!()
  end
end
