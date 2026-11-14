defmodule Tymeslot.EmailSending.UserSmtpSettingsSchemaTest do
  @moduledoc "Validates user SMTP inputs and the persistence boundary for secrets."
  use Tymeslot.DataCase, async: true

  @moduletag :emails
  @moduletag :schema

  alias Ecto.Changeset
  alias Tymeslot.EmailSending.UserSmtpSettingsSchema
  alias Tymeslot.Security.Encryption

  defp attrs do
    %{
      host: "smtp.example.com",
      port: 587,
      security: :starttls,
      username: "smtp-user",
      password: "smtp-secret",
      from_address: "booking@example.com",
      from_name: "My appointments"
    }
  end

  test "normalizes a public hostname and accepts required STARTTLS" do
    changeset =
      UserSmtpSettingsSchema.changeset(
        %UserSmtpSettingsSchema{},
        Map.put(attrs(), :host, " SMTP.EXAMPLE.COM ")
      )

    assert changeset.valid?
    assert Changeset.get_field(changeset, :host) == "smtp.example.com"
  end

  test "accepts implicit TLS on 465 and refuses mismatched transport or other ports" do
    assert UserSmtpSettingsSchema.changeset(
             %UserSmtpSettingsSchema{},
             Map.merge(attrs(), %{port: 465, security: :implicit_tls})
           ).valid?

    for invalid <- [%{port: 465}, %{security: :implicit_tls}, %{port: 25}, %{security: "none"}] do
      changeset =
        UserSmtpSettingsSchema.changeset(%UserSmtpSettingsSchema{}, Map.merge(attrs(), invalid))

      refute changeset.valid?
    end
  end

  test "refuses internal hosts, IP literals, URLs and malformed names before DNS" do
    for host <- [
          "localhost",
          "smtp.local",
          "smtp.lan",
          "smtp.internal",
          "host.home.arpa",
          "127.0.0.1",
          "8.8.8.8",
          "[::1]",
          "https://smtp.example.com",
          "smtp.example.com:587",
          "smtp.example.com/path",
          "user@smtp.example.com",
          "smtp..example.com"
        ] do
      changeset =
        UserSmtpSettingsSchema.changeset(%UserSmtpSettingsSchema{}, Map.put(attrs(), :host, host))

      assert %{host: [_host_error | _host_errors]} = errors_on(changeset), host
    end
  end

  test "refuses header controls and credential control characters" do
    for field <- [:from_address, :from_name, :username, :password] do
      value = Map.fetch!(attrs(), field) <> "\r\nBcc: other@example.com"

      changeset =
        UserSmtpSettingsSchema.changeset(
          %UserSmtpSettingsSchema{},
          Map.put(attrs(), field, value)
        )

      assert Map.has_key?(errors_on(changeset), field)
    end
  end

  test "rejects trailing header controls before trimming whitespace" do
    for {field, value} <- [
          host: "smtp.example.com",
          from_address: "booking@example.com",
          from_name: "Sender"
        ] do
      changeset =
        UserSmtpSettingsSchema.changeset(
          %UserSmtpSettingsSchema{},
          Map.put(attrs(), field, value <> "\r\n")
        )

      assert Map.has_key?(errors_on(changeset), field)
    end
  end

  test "requires a mailbox instead of a display-name header" do
    changeset =
      UserSmtpSettingsSchema.changeset(
        %UserSmtpSettingsSchema{},
        Map.put(attrs(), :from_address, "Someone <booking@example.com>")
      )

    assert %{from_address: [_address_error | _address_errors]} = errors_on(changeset)
  end

  test "rejects malformed UTF-8 before normalizing or validating string fields" do
    for field <- [:host, :from_address, :from_name, :username, :password] do
      changeset =
        UserSmtpSettingsSchema.changeset(
          %UserSmtpSettingsSchema{},
          Map.put(attrs(), field, <<255>>)
        )

      refute changeset.valid?
      assert "must be valid UTF-8" in Map.fetch!(errors_on(changeset), field)
      refute Map.has_key?(changeset.changes, field)
    end
  end

  test "requires both initial credentials" do
    changeset =
      UserSmtpSettingsSchema.changeset(
        %UserSmtpSettingsSchema{},
        Map.drop(attrs(), [:username, :password])
      )

    assert %{username: ["can't be blank"], password: ["can't be blank"]} = errors_on(changeset)
  end

  test "does not permit assigning ownership, activation or test evidence" do
    attrs =
      Map.merge(attrs(), %{
        user_id: 99,
        enabled: true,
        revision: 20,
        tested_revision: 20,
        tested_at: DateTime.utc_now()
      })

    changeset = UserSmtpSettingsSchema.changeset(%UserSmtpSettingsSchema{user_id: 7}, attrs)
    settings = Changeset.apply_changes(changeset)

    assert settings.user_id == 7
    refute settings.enabled
    assert settings.revision == 1
    assert settings.tested_revision == nil
    assert settings.tested_at == nil
  end

  test "encrypts secrets and removes virtual plaintext before insertion" do
    changeset =
      %UserSmtpSettingsSchema{}
      |> UserSmtpSettingsSchema.changeset(attrs())
      |> UserSmtpSettingsSchema.encrypt_credentials()

    settings = Changeset.apply_changes(changeset)

    assert Encryption.decrypt(settings.username_encrypted) == "smtp-user"
    assert Encryption.decrypt(settings.password_encrypted) == "smtp-secret"
    assert settings.username == nil
    assert settings.password == nil
    refute inspect(changeset) =~ "smtp-secret"
  end

  test "blank credential edits preserve ciphertext" do
    settings =
      %UserSmtpSettingsSchema{}
      |> UserSmtpSettingsSchema.changeset(attrs())
      |> UserSmtpSettingsSchema.encrypt_credentials()
      |> Changeset.apply_changes()

    changeset =
      settings
      |> UserSmtpSettingsSchema.changeset(%{username: "", password: ""})
      |> UserSmtpSettingsSchema.encrypt_credentials()

    saved = Changeset.apply_changes(changeset)

    assert changeset.valid?
    assert saved.username_encrypted == settings.username_encrypted
    assert saved.password_encrypted == settings.password_encrypted
  end

  test "bounds fields by storage bytes" do
    changeset =
      UserSmtpSettingsSchema.changeset(
        %UserSmtpSettingsSchema{},
        Map.merge(attrs(), %{
          from_name: String.duplicate("é", 128),
          username: String.duplicate("u", 1025),
          password: String.duplicate("p", 4097)
        })
      )

    assert %{
             from_name: [_name_error | _name_errors],
             username: [_username_error | _username_errors],
             password: [_password_error | _password_errors]
           } = errors_on(changeset)
  end
end
