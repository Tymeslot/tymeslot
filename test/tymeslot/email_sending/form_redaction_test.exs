defmodule Tymeslot.EmailSending.FormRedactionTest do
  @moduledoc "Verifies that public form changesets contain no SMTP credentials or untrusted params."

  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :security

  import Tymeslot.ConfigTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.EmailSending
  alias Tymeslot.EmailSending.{SettingsQueries, UserSmtpSettingsSchema}
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.FakeSmtpRelay

  defmodule Destination do
    @moduledoc false
    @behaviour Tymeslot.EmailSending.Destination

    @impl Tymeslot.EmailSending.Destination
    def resolve(_host, _port) do
      {:ok,
       %{address: {127, 0, 0, 1}, port: Application.fetch_env!(:tymeslot, :smtp_form_test_port)}}
    end
  end

  setup_all do
    %{certificates: FakeSmtpRelay.certificates(~c"smtp.example.com")}
  end

  setup %{certificates: certificates} do
    with_config(:tymeslot,
      user_smtp_enabled: true,
      user_smtp_destination_module: Destination,
      user_smtp_cacertfile: certificates.cacertfile
    )

    owner = insert(:user)

    settings =
      Repo.insert!(%UserSmtpSettingsSchema{
        user_id: owner.id,
        host: "smtp.example.com",
        port: 587,
        security: :starttls,
        username_encrypted: Encryption.encrypt("stored-login-secret"),
        password_encrypted: Encryption.encrypt("stored-password-secret"),
        from_address: "bookings@example.com",
        from_name: "Booking brand",
        enabled: true,
        revision: 1,
        tested_revision: 1,
        tested_at: DateTime.utc_now()
      })

    %{owner: owner, settings: settings}
  end

  test "new-candidate form validation retains public values while dropping submitted credentials",
       %{
         owner: owner,
         settings: settings
       } do
    Repo.delete!(settings)

    assert {:ok, changeset} = EmailSending.change_settings(owner, attrs())
    assert changeset.valid?
    assert Changeset.get_field(changeset, :host) == "smtp.example.com"
    assert Changeset.get_field(changeset, :from_name) == "New booking brand"
    assert changeset.params["from_address"] == "new@example.com"
    assert_redacted(changeset, ["submitted-login-secret", "submitted-password-secret"])
  end

  test "blank edits validate against stored credentials but return no ciphertext", context do
    assert {:ok, changeset} =
             EmailSending.change_settings(context.owner, %{
               "username" => "",
               "password" => "",
               "from_name" => "Updated brand"
             })

    assert changeset.valid?
    assert Changeset.get_field(changeset, :from_name) == "Updated brand"

    assert_redacted(changeset, [
      context.settings.username_encrypted,
      context.settings.password_encrypted,
      "stored-login-secret",
      "stored-password-secret"
    ])

    assert Repo.reload!(context.settings) == context.settings
  end

  test "invalid fields preserve their errors without retaining secret or ignored parameters",
       context do
    secret = "invalid-password-secret\n"

    attrs = %{
      "host" => "127.0.0.1",
      "password" => secret,
      "username" => "invalid-login-secret\n",
      "from_name" => "Updated brand",
      "recipient" => "ignored-recipient-secret",
      "password_encrypted" => "ignored-ciphertext-secret"
    }

    assert {:ok, changeset} = EmailSending.change_settings(context.owner, attrs)
    refute changeset.valid?
    assert errors_on(changeset).host == ["must be a public SMTP hostname"]
    assert errors_on(changeset).password == ["must not contain control characters"]
    assert changeset.params == %{"host" => "127.0.0.1", "from_name" => "Updated brand"}

    assert_redacted(changeset, [
      secret,
      "invalid-login-secret",
      "ignored-recipient-secret",
      "ignored-ciphertext-secret",
      context.settings.password_encrypted
    ])
  end

  test "test-and-save validation errors use the same secret-free presentation contract",
       context do
    attrs = Map.merge(attrs(), %{host: "127.0.0.1", password: "invalid-password-secret\n"})

    assert {:error, %Changeset{} = changeset} =
             EmailSending.test_and_save_settings(context.owner, attrs, version(context.settings))

    assert changeset.action == :validate
    assert errors_on(changeset).host == ["must be a public SMTP hostname"]

    assert_redacted(changeset, [
      "submitted-login-secret",
      "invalid-password-secret",
      context.settings.username_encrypted,
      context.settings.password_encrypted
    ])

    assert Repo.reload!(context.settings) == context.settings
    refute_received {:smtp_relay, _event}
  end

  test "unknown stored failure text is never returned through a public form", context do
    context.settings
    |> Changeset.change(last_error: "raw-relay-password-secret")
    |> Repo.update!()

    assert {:ok, changeset} = EmailSending.change_settings(context.owner, %{})
    assert changeset.data.last_error == "delivery_failed"
    refute :erlang.term_to_binary(changeset) =~ "raw-relay-password-secret"
  end

  test "test sends use the current verified account email instead of a stale socket user",
       context do
    Repo.delete!(context.settings)
    new_email = "current-verified-account@example.com"

    context.owner
    |> Changeset.change(email: new_email)
    |> Repo.update!()

    use_relay(context.certificates)

    assert {:ok, settings} = EmailSending.test_and_save_settings(context.owner, attrs(), :new)
    refute settings.enabled
    assert_receive {:smtp_relay, {:message, message}}, 2_000
    assert message =~ new_email
    refute message =~ context.owner.email

    stored = SettingsQueries.get_for_user(context.owner.id)
    assert Encryption.decrypt(stored.password_encrypted) == "submitted-password-secret"
  end

  test "a formerly verified socket cannot test or enable after account verification is removed",
       context do
    context.owner |> Changeset.change(verified_at: nil) |> Repo.update!()

    assert {:error, :unverified_user} =
             EmailSending.test_and_save_settings(context.owner, %{}, version(context.settings))

    assert {:error, :unverified_user} =
             EmailSending.enable_settings(context.owner, version(context.settings))

    refute_received {:smtp_relay, _event}
    assert Repo.reload!(context.settings) == context.settings
  end

  test "a deleted account cannot test or activate using its former verified socket", context do
    Repo.delete!(context.owner)

    assert {:error, :invalid_user} =
             EmailSending.test_and_save_settings(context.owner, attrs(), :new)

    assert {:error, :invalid_user} =
             EmailSending.enable_settings(context.owner, version(context.settings))

    refute_received {:smtp_relay, _event}
    assert Repo.get(UserSchema, context.owner.id) == nil
  end

  defp attrs do
    %{
      host: "smtp.example.com",
      port: 587,
      security: :starttls,
      username: "submitted-login-secret",
      password: "submitted-password-secret",
      from_address: "new@example.com",
      from_name: "New booking brand"
    }
  end

  defp version(settings), do: {settings.id, settings.revision}

  defp use_relay(certificates) do
    relay = FakeSmtpRelay.start(starttls: certificates)
    with_config(:tymeslot, smtp_form_test_port: relay.port)
  end

  defp assert_redacted(changeset, secrets) do
    for field <- [:username, :password, :username_encrypted, :password_encrypted] do
      assert Map.fetch!(changeset.data, field) == nil
      refute Map.has_key?(changeset.changes, field)
      refute Map.has_key?(changeset.params || %{}, Atom.to_string(field))
    end

    encoded = :erlang.term_to_binary(changeset)
    for secret <- secrets, do: assert(:binary.match(encoded, secret) == :nomatch)
  end
end
