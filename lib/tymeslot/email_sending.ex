defmodule Tymeslot.EmailSending do
  @moduledoc """
  User-owned SMTP identities. A successful send to the verified account owner
  is required before saving and enabling a configuration. Existing notification
  routing does not use these settings until a later delivery integration.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @behaviour Tymeslot.Security.EncryptedStorage

  alias Ecto.Changeset
  alias Swoosh.Email
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Clock
  alias Tymeslot.EmailSending.{Settings, SettingsQueries, Transport, UserSmtpSettingsSchema}
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Security.RateLimiter

  @type result :: {:ok, Settings.t()} | {:error, term()}
  @max_id 9_223_372_036_854_775_807
  @max_revision 2_147_483_646

  @doc "Whether the operator enabled the per-user SMTP feature."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:tymeslot, :user_smtp_enabled, false) == true

  @doc "The owner's saved settings, with every credential omitted."
  @spec get_settings(UserSchema.t()) :: result()
  def get_settings(user) do
    with {:ok, user_id} <- owner_id(user),
         %UserSmtpSettingsSchema{} = settings <- SettingsQueries.get_for_user(user_id) do
      {:ok, Settings.from_schema(settings)}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Validates editable settings for the owner without contacting an SMTP server."
  @spec change_settings(UserSchema.t(), map()) :: {:ok, Changeset.t()} | {:error, term()}
  def change_settings(user, attrs) when is_map(attrs) do
    with {:ok, user_id} <- owner_id(user) do
      settings =
        SettingsQueries.get_for_user(user_id) || %UserSmtpSettingsSchema{user_id: user_id}

      {:ok, UserSmtpSettingsSchema.changeset(settings, attrs)}
    end
  end

  def change_settings(_user, _attrs), do: {:error, :invalid_settings}

  @doc """
  Tests the candidate against the verified owner's address, then saves the
  tested revision. New settings are disabled; replacements retain activation.
  A failed test or stale revision leaves the saved configuration intact.

  `expected_version` is `:new` for a first configuration and `{id, revision}`
  for an existing one, so deleted settings cannot be replaced by a stale form. Stored credentials
  are reused when their edit fields are blank. Client-supplied lifecycle and
  ownership fields are never cast.
  """
  @spec test_and_save_settings(UserSchema.t(), map(), :new | Settings.version()) :: result()
  def test_and_save_settings(user, attrs, expected_version) when is_map(attrs) do
    with :ok <- require_enabled(),
         {:ok, user_id} <- verified_owner_id(user),
         :ok <- valid_version(expected_version),
         {:ok, settings} <- load_revision(user_id, expected_version),
         changeset = UserSmtpSettingsSchema.changeset(settings, attrs),
         {:ok, candidate} <- Changeset.apply_action(changeset, :validate),
         {:ok, transport} <- transport_credentials(candidate),
         :ok <- charge_test(user_id),
         {:ok, _receipt} <- Transport.deliver(test_email(user, candidate), transport),
         {:ok, saved} <- persist_tested(settings, changeset) do
      {:ok, Settings.from_schema(saved)}
    end
  end

  def test_and_save_settings(_user, _attrs, _revision), do: {:error, :invalid_settings}

  @doc "Enables only the owner's current successfully tested revision."
  @spec enable_settings(UserSchema.t(), Settings.version()) :: result()
  def enable_settings(user, expected_version) do
    with :ok <- require_enabled(),
         {:ok, user_id} <- verified_owner_id(user),
         :ok <- valid_version(expected_version),
         {:ok, settings} <- load_existing_revision(user_id, expected_version),
         :ok <- tested?(settings),
         {:ok, _credentials} <- transport_credentials(settings),
         {:ok, saved} <- settings |> Changeset.change(enabled: true) |> update_lifecycle() do
      {:ok, Settings.from_schema(saved)}
    end
  end

  @doc "Disables the owner's current revision even while the feature is turned off."
  @spec disable_settings(UserSchema.t(), Settings.version()) :: result()
  def disable_settings(user, expected_version) do
    with {:ok, user_id} <- owner_id(user),
         :ok <- valid_version(expected_version),
         {:ok, settings} <- load_existing_revision(user_id, expected_version),
         {:ok, saved} <- settings |> Changeset.change(enabled: false) |> update_lifecycle() do
      {:ok, Settings.from_schema(saved)}
    end
  end

  @doc "Deletes the owner's current configuration, including encrypted credentials."
  @spec delete_settings(UserSchema.t(), Settings.version()) :: :ok | {:error, term()}
  def delete_settings(user, expected_version) do
    with {:ok, user_id} <- owner_id(user),
         :ok <- valid_version(expected_version) do
      delete_version(user_id, expected_version)
    end
  end

  @impl Tymeslot.Security.EncryptedStorage
  @doc "The SMTP ciphertext columns included in key rotation and key reports."
  @spec encrypted_storage() :: Tymeslot.Security.EncryptedStorage.table()
  def encrypted_storage do
    {UserSmtpSettingsSchema.__schema__(:source),
     UserSmtpSettingsSchema.encrypted_credential_fields()}
  end

  defp owner_id(%UserSchema{id: id}) when is_integer(id) and id > 0 and id <= @max_id,
    do: {:ok, id}

  defp owner_id(_user), do: {:error, :invalid_user}

  defp verified_owner_id(%UserSchema{verified_at: %DateTime{}, email: email} = user)
       when is_binary(email) and email != "",
       do: owner_id(user)

  defp verified_owner_id(_user), do: {:error, :unverified_user}

  defp require_enabled do
    if enabled?(), do: :ok, else: {:error, :feature_disabled}
  end

  defp valid_version(:new), do: :ok

  defp valid_version({id, revision})
       when is_integer(id) and id > 0 and id <= @max_id and
              is_integer(revision) and revision > 0 and revision <= @max_revision,
       do: :ok

  defp valid_version(_version), do: {:error, :invalid_version}

  defp delete_version(user_id, {id, revision}), do: SettingsQueries.delete(user_id, id, revision)
  defp delete_version(_user_id, :new), do: {:error, :not_found}

  defp charge_test(user_id) do
    case RateLimiter.consume(:user_smtp_test, user_id, 1) do
      :ok -> :ok
      {:error, {:rate_limited, _remaining}} -> {:error, :rate_limited}
    end
  end

  defp load_revision(user_id, expected_version) do
    case {SettingsQueries.get_for_user(user_id), expected_version} do
      {nil, :new} ->
        {:ok, %UserSmtpSettingsSchema{user_id: user_id}}

      {%UserSmtpSettingsSchema{id: id, revision: revision} = settings, {id, revision}} ->
        {:ok, settings}

      _missing_or_changed ->
        {:error, :stale}
    end
  end

  defp load_existing_revision(_user_id, :new), do: {:error, :not_found}
  defp load_existing_revision(user_id, version), do: load_revision(user_id, version)

  defp transport_credentials(candidate) do
    with {:ok, username} <- credential(candidate.username, candidate.username_encrypted),
         {:ok, password} <- credential(candidate.password, candidate.password_encrypted) do
      {:ok,
       %{
         host: candidate.host,
         port: candidate.port,
         security: candidate.security,
         username: username,
         password: password
       }}
    end
  end

  defp credential(value, _encrypted) when is_binary(value) and value != "", do: {:ok, value}

  defp credential(_value, encrypted) do
    case Encryption.decrypt_with_status(encrypted) do
      {:ok, plaintext} when is_binary(plaintext) and plaintext != "" -> {:ok, plaintext}
      _unavailable -> {:error, :credentials_unavailable}
    end
  end

  defp test_email(user, candidate) do
    Email.new()
    |> Email.from({candidate.from_name, candidate.from_address})
    |> Email.to(user.email)
    |> Email.subject(dgettext("emails_account", "SMTP sending test"))
    |> Email.text_body(dgettext("emails_account", "Your SMTP server accepted this test message."))
  end

  defp persist_tested(settings, changeset) do
    revision = if is_nil(settings.id), do: 1, else: settings.revision + 1

    changeset =
      changeset
      |> UserSmtpSettingsSchema.encrypt_credentials()
      |> Changeset.change(
        tested_revision: revision,
        tested_at: Clock.utc_now(),
        last_error: nil,
        last_failed_at: nil
      )

    if is_nil(settings.id),
      do: SettingsQueries.insert(changeset),
      else: SettingsQueries.update(changeset)
  end

  defp tested?(%UserSmtpSettingsSchema{
         revision: revision,
         tested_revision: revision,
         tested_at: %DateTime{}
       }),
       do: :ok

  defp tested?(_settings), do: {:error, :not_tested}

  # Activation changes invalidate older forms but do not change the tested
  # SMTP payload. Carry its test evidence to the new lifecycle revision.
  defp update_lifecycle(changeset) do
    if changeset.data.tested_revision == changeset.data.revision do
      changeset
      |> Changeset.change(tested_revision: changeset.data.revision + 1)
      |> SettingsQueries.update()
    else
      SettingsQueries.update(changeset)
    end
  end
end
