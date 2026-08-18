defmodule Tymeslot.Integrations.Video.VideoIntegrationSchema do
  @moduledoc """
  Schema for video conferencing integrations (MiroTalk).
  """
  use Ecto.Schema
  use Gettext, backend: TymeslotWeb.Gettext
  import Ecto.Changeset
  alias Tymeslot.ChangesetValidators.URL, as: URLValidator
  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Security.Encryption

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer() | nil,
          name: String.t() | nil,
          provider: String.t(),
          base_url: String.t() | nil,
          api_key_encrypted: binary() | nil,
          access_token_encrypted: binary() | nil,
          refresh_token_encrypted: binary() | nil,
          account_id_encrypted: binary() | nil,
          client_id_encrypted: binary() | nil,
          client_secret_encrypted: binary() | nil,
          tenant_id_encrypted: binary() | nil,
          teams_user_id_encrypted: binary() | nil,
          custom_meeting_url: String.t() | nil,
          token_expires_at: DateTime.t() | nil,
          oauth_scope: String.t() | nil,
          provider_account_id: String.t() | nil,
          provider_account_email: String.t() | nil,
          is_active: boolean(),
          needs_reauth: boolean(),
          sync_error: String.t() | nil,
          deleted_at: DateTime.t() | nil,
          settings: map(),
          user: Tymeslot.Auth.UserSchema.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "video_integrations" do
    field(:name, :string)
    field(:provider, :string, default: "mirotalk")
    field(:base_url, :string)
    field(:api_key_encrypted, :binary)
    field(:access_token_encrypted, :binary)
    field(:refresh_token_encrypted, :binary)
    field(:account_id_encrypted, :binary)
    field(:client_id_encrypted, :binary)
    field(:client_secret_encrypted, :binary)
    field(:tenant_id_encrypted, :binary)
    field(:teams_user_id_encrypted, :binary)
    field(:custom_meeting_url, :string)
    field(:token_expires_at, :utc_datetime)
    field(:oauth_scope, :string)
    field(:provider_account_id, :string)
    field(:provider_account_email, :string)
    field(:is_active, :boolean, default: true)
    field(:needs_reauth, :boolean, default: false)
    field(:sync_error, :string)
    # Set when the user disconnects and asked for the provider-side rooms to be
    # deleted: the row survives, hidden, only long enough for the cleanup job to
    # use its credentials.
    field(:deleted_at, :utc_datetime)
    field(:settings, :map, default: %{})

    # Virtual fields for decrypted credentials
    field(:api_key, :string, virtual: true, redact: true)
    field(:access_token, :string, virtual: true, redact: true)
    field(:refresh_token, :string, virtual: true, redact: true)
    field(:account_id, :string, virtual: true, redact: true)
    field(:client_id, :string, virtual: true, redact: true)
    field(:client_secret, :string, virtual: true, redact: true)
    field(:tenant_id, :string, virtual: true, redact: true)
    field(:teams_user_id, :string, virtual: true, redact: true)

    belongs_to(:user, Tymeslot.Auth.UserSchema)

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(video_integration, attrs) do
    video_integration
    |> cast(attrs, [
      :name,
      :provider,
      :base_url,
      :api_key,
      :access_token,
      :refresh_token,
      :account_id,
      :client_id,
      :client_secret,
      :tenant_id,
      :teams_user_id,
      :custom_meeting_url,
      :token_expires_at,
      :oauth_scope,
      :provider_account_id,
      :provider_account_email,
      :is_active,
      :settings,
      :user_id
    ])
    |> validate_required([:name, :provider, :user_id])
    |> validate_inclusion(
      :provider,
      ProviderConfig.provider_constraint_list_all()
    )
    |> validate_provider_specific_fields()
    |> encrypt_credentials()
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :provider, :provider_account_id],
      name: :unique_active_video_account_per_user,
      # `TymeslotWeb.Components.CoreComponents.Forms.translate_error/1` runs the stored msgid
      # through the "errors" domain at render time, so the changeset must
      # carry the untranslated msgid — hence `dgettext_noop/2`, not
      # `dgettext/2`, which would translate here and miss the lookup there.
      message: dgettext_noop("errors", "an integration for this account already exists")
    )
    |> unique_constraint([:user_id, :provider],
      name: :unique_active_video_null_account_per_user,
      message: dgettext_noop("errors", "an integration for this provider already exists")
    )
  end

  @doc """
  Changeset for flipping `is_active`.

  Carries the same uniqueness declarations as the main changeset, because both
  partial indexes are predicated on `is_active = true`: reactivating a row moves
  it *into* the index and genuinely contends. A bare `Ecto.Changeset.change/2`
  declares none of them, so a violation raises `Ecto.ConstraintError` instead of
  returning an invalid changeset the caller can render.
  """
  @spec activation_changeset(t(), boolean()) :: Ecto.Changeset.t()
  def activation_changeset(%__MODULE__{} = integration, is_active) do
    integration
    |> change(%{is_active: is_active})
    |> unique_constraint([:user_id, :provider, :provider_account_id],
      name: :unique_active_video_account_per_user,
      message: dgettext_noop("errors", "an integration for this account already exists")
    )
    |> unique_constraint([:user_id, :provider],
      name: :unique_active_video_null_account_per_user,
      message: dgettext_noop("errors", "an integration for this provider already exists")
    )
  end

  @doc """
  Decrypts the credential fields.
  """
  @spec decrypt_credentials(t()) :: t()
  def decrypt_credentials(%__MODULE__{} = integration) do
    %{
      integration
      | api_key: safe_decrypt(integration.api_key_encrypted, "api_key", integration.id),
        access_token:
          safe_decrypt(integration.access_token_encrypted, "access_token", integration.id),
        refresh_token:
          safe_decrypt(integration.refresh_token_encrypted, "refresh_token", integration.id),
        account_id: safe_decrypt(integration.account_id_encrypted, "account_id", integration.id),
        client_id: safe_decrypt(integration.client_id_encrypted, "client_id", integration.id),
        client_secret:
          safe_decrypt(integration.client_secret_encrypted, "client_secret", integration.id),
        tenant_id: safe_decrypt(integration.tenant_id_encrypted, "tenant_id", integration.id),
        teams_user_id:
          safe_decrypt(integration.teams_user_id_encrypted, "teams_user_id", integration.id)
    }
  end

  defp safe_decrypt(nil, _field, _id), do: nil

  defp safe_decrypt(encrypted, field, id) do
    Encryption.decrypt(encrypted)
  rescue
    _e ->
      require Logger

      Logger.error("Failed to decrypt video integration field",
        field: field,
        integration_id: id
      )

      nil
  end

  @encrypted_credential_fields [
    :api_key_encrypted,
    :access_token_encrypted,
    :refresh_token_encrypted,
    :account_id_encrypted,
    :client_id_encrypted,
    :client_secret_encrypted,
    :tenant_id_encrypted,
    :teams_user_id_encrypted
  ]

  # The virtual counterparts callers actually write. Derived from the encrypted
  # list so the two cannot drift: `attrs` carry `:api_key`, never
  # `:api_key_encrypted`, which only exists after `encrypt_credentials/1` runs.
  @credential_fields Enum.map(@encrypted_credential_fields, fn field ->
                       field
                       |> Atom.to_string()
                       |> String.replace_suffix("_encrypted", "")
                       |> String.to_atom()
                     end)

  @doc """
  Returns the list of encrypted credential field atoms on this schema. Used by
  `decryption_status/1` so the authoritative list lives in one place.
  """
  @spec encrypted_credential_fields() :: [atom()]
  def encrypted_credential_fields, do: @encrypted_credential_fields

  @doc """
  Returns the virtual credential field atoms a caller supplies in `attrs`.

  Use this when deciding whether an update carries credentials the owner just
  supplied; the encrypted names never appear in caller-supplied attrs.
  """
  @spec credential_fields() :: [atom()]
  def credential_fields, do: @credential_fields

  @doc """
  Reports whether any encrypted credential on the integration fails to decrypt
  under the current keyring. Returns `:ok` when every ciphertext is either
  absent or decryptable, `:requires_reencryption` otherwise.

  Used by workers to short-circuit jobs when SECRET_KEY_BASE has been
  rotated without keeping the previous key on the keyring — the worker can
  then flag `needs_reauth` so the user sees a reconnect prompt.
  """
  @spec decryption_status(t()) :: :ok | :requires_reencryption
  def decryption_status(%__MODULE__{} = integration) do
    encrypted_values = Enum.map(@encrypted_credential_fields, &Map.get(integration, &1))

    if Enum.any?(
         encrypted_values,
         &(Encryption.decrypt_with_status(&1) == {:error, :requires_reencryption})
       ) do
      :requires_reencryption
    else
      :ok
    end
  end

  # Private functions

  defp validate_provider_specific_fields(changeset) do
    with {:ok, provider_type} <- ProviderConfig.parse_known(get_field(changeset, :provider)),
         module when module != nil <- ProviderConfig.get_provider_module(provider_type) do
      apply_credential_spec(changeset, module.credential_spec())
    else
      _other -> changeset
    end
  end

  defp apply_credential_spec(changeset, spec) do
    changeset
    |> validate_required(spec.required)
    |> apply_credential_pairs(spec.credential_pairs)
    |> apply_url_validations(spec.url_fields)
  end

  defp apply_credential_pairs(changeset, pairs) do
    Enum.reduce(pairs, changeset, fn {virtual, encrypted}, acc ->
      require_credential_if_absent(acc, virtual, encrypted)
    end)
  end

  defp apply_url_validations(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      URLValidator.validate_url(acc, field, block_private_ips: true)
    end)
  end

  # Only require a virtual credential field when the persisted encrypted
  # counterpart is absent — i.e., the credential hasn't been stored yet.
  defp require_credential_if_absent(changeset, virtual_field, encrypted_field) do
    if get_field(changeset, encrypted_field) do
      changeset
    else
      validate_required(changeset, [virtual_field])
    end
  end

  defp encrypt_credentials(changeset) do
    changeset
    |> encrypt_field(:api_key, :api_key_encrypted)
    |> encrypt_field(:access_token, :access_token_encrypted)
    |> encrypt_field(:refresh_token, :refresh_token_encrypted)
    |> encrypt_field(:account_id, :account_id_encrypted)
    |> encrypt_field(:client_id, :client_id_encrypted)
    |> encrypt_field(:client_secret, :client_secret_encrypted)
    |> encrypt_field(:tenant_id, :tenant_id_encrypted)
    |> encrypt_field(:teams_user_id, :teams_user_id_encrypted)
  end

  defp encrypt_field(changeset, field, encrypted_field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      value ->
        changeset
        |> put_change(encrypted_field, Encryption.encrypt(value))
        |> delete_change(field)
    end
  end
end
