defmodule Tymeslot.EmailSendingTest.Destination do
  @moduledoc "Maps a logical public relay to this module's loopback TLS fixture."

  @doc "Returns the test relay endpoint without adding a user-controlled bypass."
  @spec resolve(String.t(), pos_integer()) ::
          {:ok, %{address: :inet.ip_address(), port: pos_integer()}}
  def resolve("smtp.example.com", _port) do
    {:ok,
     %{address: {127, 0, 0, 1}, port: Application.fetch_env!(:tymeslot, :smtp_domain_test_port)}}
  end
end

defmodule Tymeslot.EmailSendingTest do
  @moduledoc "Exercises owner scoping and the tested SMTP configuration lifecycle."
  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :integration

  import Tymeslot.ConfigTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.EmailSending
  alias Tymeslot.EmailSending.{Settings, SettingsQueries, UserSmtpSettingsSchema}
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Test.FakeSmtpRelay

  setup_all do
    %{certs: FakeSmtpRelay.certificates(~c"smtp.example.com")}
  end

  setup %{certs: certs} do
    relay = FakeSmtpRelay.start(starttls: certs)

    with_config(:tymeslot,
      user_smtp_enabled: true,
      user_smtp_destination_module: Tymeslot.EmailSendingTest.Destination,
      user_smtp_cacertfile: certs.cacertfile,
      smtp_domain_test_port: relay.port
    )

    %{user: insert(:user, verified_at: DateTime.utc_now(:second))}
  end

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

  defp save(user), do: EmailSending.test_and_save_settings(user, attrs(), :new)

  test "sends a real TLS/authenticated test to its owner and saves a disabled tested revision", %{
    user: user
  } do
    assert {:ok, settings} = save(user)
    refute settings.enabled
    assert settings.revision == 1
    assert settings.tested_revision == 1
    assert %DateTime{} = settings.tested_at
    assert settings.credentials_configured
    assert_received {:smtp_relay, {:message, message}}
    assert message =~ user.email
    assert message =~ "booking@example.com"
    refute inspect(settings) =~ "smtp-secret"
    refute Map.has_key?(Map.from_struct(settings), :password_encrypted)

    persisted = SettingsQueries.get_for_user(user.id)
    assert Encryption.decrypt(persisted.password_encrypted) == "smtp-secret"
    assert persisted.password == nil
  end

  test "never accepts a submitted owner, test recipient, or activation", %{user: user} do
    other = insert(:user)

    attrs =
      Map.merge(attrs(), %{
        user_id: other.id,
        recipient: other.email,
        enabled: true,
        tested_revision: 50,
        revision: 50
      })

    assert {:ok, settings} = EmailSending.test_and_save_settings(user, attrs, :new)
    refute settings.enabled
    assert settings.revision == 1
    assert SettingsQueries.get_for_user(other.id) == nil
    assert_received {:smtp_relay, {:message, message}}
    assert message =~ user.email
    refute message =~ other.email
  end

  test "ordinary reads are owner scoped and credential free", %{user: user} do
    assert {:ok, settings} = save(user)
    assert {:ok, ^settings} = EmailSending.get_settings(user)
    assert {:error, :not_found} = EmailSending.get_settings(insert(:user))
  end

  test "gates testing and activation before network access when disabled", %{user: user} do
    with_config(:tymeslot, user_smtp_enabled: false)
    assert {:error, :feature_disabled} = save(user)
    assert {:error, :feature_disabled} = EmailSending.enable_settings(user, {1, 1})
    assert SettingsQueries.get_for_user(user.id) == nil
    refute_received {:smtp_relay, :ehlo}
  end

  test "a verified account is required before test sends", %{user: user} do
    assert {:error, :unverified_user} = save(%{user | verified_at: nil})
    refute_received {:smtp_relay, :ehlo}
  end

  test "charges test attempts to the owner before opening an SMTP connection", %{user: user} do
    assert :ok = RateLimiter.consume(:user_smtp_test, user.id, 5)
    assert {:error, :rate_limited} = save(user)
    assert SettingsQueries.get_for_user(user.id) == nil
    refute_received {:smtp_relay, :ehlo}
  end

  test "invalid inputs and revisions fail without connecting", %{user: user} do
    assert {:error, :invalid_user} = EmailSending.get_settings(%{id: user.id})
    assert {:error, :invalid_version} = EmailSending.test_and_save_settings(user, attrs(), "0")

    assert {:error, %Changeset{}} =
             EmailSending.test_and_save_settings(user, Map.put(attrs(), :host, "127.0.0.1"), :new)

    assert {:error, :invalid_settings} = EmailSending.test_and_save_settings(user, nil, :new)
    refute_received {:smtp_relay, :ehlo}
  end

  test "malformed UTF-8 settings return validation errors without contacting SMTP", %{user: user} do
    for field <- [:host, :from_address, :from_name, :username, :password] do
      assert {:error, %Changeset{} = changeset} =
               EmailSending.test_and_save_settings(user, Map.put(attrs(), field, <<255>>), :new)

      assert "must be valid UTF-8" in Map.fetch!(errors_on(changeset), field)
    end

    assert SettingsQueries.get_for_user(user.id) == nil
    refute_received {:smtp_relay, :ehlo}
  end

  test "activation requires test evidence and retains that evidence over lifecycle edits", %{
    user: user
  } do
    assert {:ok, settings} = save(user)
    assert {:ok, enabled} = EmailSending.enable_settings(user, Settings.version(settings))
    assert enabled.enabled
    assert enabled.revision == 2
    assert enabled.tested_revision == 2
    assert {:error, :stale} = EmailSending.disable_settings(user, Settings.version(settings))
    assert {:ok, disabled} = EmailSending.disable_settings(user, Settings.version(enabled))
    refute disabled.enabled
    assert disabled.tested_revision == disabled.revision
  end

  test "editing a disabled or active identity retains blank passwords and replaces only a tested payload",
       %{user: user} do
    assert {:ok, settings} = save(user)
    assert {:ok, active} = EmailSending.enable_settings(user, Settings.version(settings))

    assert {:ok, changed} =
             EmailSending.test_and_save_settings(
               user,
               %{from_name: "New sender", password: "", username: ""},
               Settings.version(active)
             )

    assert changed.enabled
    assert changed.from_name == "New sender"
    assert changed.tested_revision == changed.revision

    assert Encryption.decrypt(SettingsQueries.get_for_user(user.id).password_encrypted) ==
             "smtp-secret"
  end

  test "a saved configuration without a successful test cannot be enabled", %{user: user} do
    changeset =
      %UserSmtpSettingsSchema{user_id: user.id}
      |> UserSmtpSettingsSchema.changeset(attrs())
      |> UserSmtpSettingsSchema.encrypt_credentials()

    assert {:ok, untested} = SettingsQueries.insert(changeset)

    assert {:error, :not_tested} =
             EmailSending.enable_settings(user, {untested.id, untested.revision})

    refute SettingsQueries.get_for_user(user.id).enabled
  end

  test "a stale test candidate cannot replace current settings", %{user: user} do
    assert {:ok, settings} = save(user)
    assert {:ok, enabled} = EmailSending.enable_settings(user, Settings.version(settings))

    assert {:error, :stale} =
             EmailSending.test_and_save_settings(
               user,
               %{password: "replacement"},
               Settings.version(settings)
             )

    assert {:ok, ^enabled} = EmailSending.get_settings(user)
  end

  test "the write boundary rejects a candidate tested before a concurrent lifecycle edit", %{
    user: user
  } do
    assert {:ok, settings} = save(user)
    before_test = SettingsQueries.get_for_user(user.id)
    assert {:ok, disabled} = EmailSending.disable_settings(user, Settings.version(settings))

    candidate =
      before_test
      |> UserSmtpSettingsSchema.changeset(%{from_name: "Stale candidate"})
      |> Changeset.change(tested_revision: before_test.revision + 1)

    assert {:error, :stale} = SettingsQueries.update(candidate)
    assert {:ok, ^disabled} = EmailSending.get_settings(user)
  end

  test "a form for a deleted configuration cannot affect its replacement", %{user: user} do
    assert {:ok, original} = save(user)
    original_version = Settings.version(original)
    assert :ok = EmailSending.delete_settings(user, original_version)
    assert {:ok, replacement} = save(user)
    assert replacement.id != original.id
    assert replacement.revision == original.revision
    assert_received {:smtp_relay, {:message, _first_test}}
    assert_received {:smtp_relay, {:message, _replacement_test}}

    assert {:error, :stale} = EmailSending.enable_settings(user, original_version)
    assert {:error, :stale} = EmailSending.disable_settings(user, original_version)
    assert {:error, :stale} = EmailSending.delete_settings(user, original_version)

    assert {:error, :stale} =
             EmailSending.test_and_save_settings(
               user,
               %{password: "stale-secret"},
               original_version
             )

    assert {:ok, ^replacement} = EmailSending.get_settings(user)
    refute_received {:smtp_relay, {:message, _unexpected_test}}
  end

  test "failed SMTP authentication leaves an active configuration intact", %{
    user: user,
    certs: certs
  } do
    assert {:ok, settings} = save(user)
    assert {:ok, enabled} = EmailSending.enable_settings(user, Settings.version(settings))
    relay = FakeSmtpRelay.start(starttls: certs, auth: :reject)
    with_config(:tymeslot, smtp_domain_test_port: relay.port)

    assert {:error, :authentication_failed} =
             EmailSending.test_and_save_settings(
               user,
               %{password: "replacement"},
               Settings.version(enabled)
             )

    assert {:ok, ^enabled} = EmailSending.get_settings(user)

    assert Encryption.decrypt(SettingsQueries.get_for_user(user.id).password_encrypted) ==
             "smtp-secret"
  end

  test "unavailable encryption keys fail closed before testing or overwriting", %{user: user} do
    assert {:ok, settings} = save(user)

    Repo.update_all(from(s in UserSmtpSettingsSchema, where: s.user_id == ^user.id),
      set: [password_encrypted: :crypto.strong_rand_bytes(80)]
    )

    assert {:error, :credentials_unavailable} =
             EmailSending.test_and_save_settings(
               user,
               %{from_name: "New sender"},
               Settings.version(settings)
             )

    assert {:error, :credentials_unavailable} =
             EmailSending.enable_settings(user, Settings.version(settings))
  end

  test "disable and delete remain available when the feature is disabled", %{user: user} do
    assert {:ok, settings} = save(user)
    with_config(:tymeslot, user_smtp_enabled: false)
    assert {:ok, disabled} = EmailSending.disable_settings(user, Settings.version(settings))
    assert :ok = EmailSending.delete_settings(user, Settings.version(disabled))
    assert {:error, :not_found} = EmailSending.get_settings(user)
  end

  test "deleting another account's revision cannot remove the owner's settings", %{user: user} do
    assert {:ok, settings} = save(user)

    assert {:error, :stale} =
             EmailSending.delete_settings(insert(:user), Settings.version(settings))

    assert {:ok, ^settings} = EmailSending.get_settings(user)
  end

  test "deleting a user cascades to the SMTP credentials", %{user: user} do
    assert {:ok, _settings} = save(user)
    Repo.delete!(user)
    assert SettingsQueries.get_for_user(user.id) == nil
  end

  test "database enforces one configuration per owner", %{user: user} do
    assert {:ok, _settings} = save(user)

    changeset =
      %UserSmtpSettingsSchema{user_id: user.id}
      |> UserSmtpSettingsSchema.changeset(attrs())
      |> UserSmtpSettingsSchema.encrypt_credentials()

    assert {:error, :stale} = SettingsQueries.insert(changeset)
  end
end
