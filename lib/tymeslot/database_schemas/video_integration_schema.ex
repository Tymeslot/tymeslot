defmodule Tymeslot.DatabaseSchemas.VideoIntegrationSchema do
  @moduledoc """
  Schema for video conferencing integrations (MiroTalk).
  """
  use Ecto.Schema
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
          is_active: boolean(),
          is_default: boolean(),
          settings: map(),
          user: Tymeslot.DatabaseSchemas.UserSchema.t() | Ecto.Association.NotLoaded.t(),
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
    field(:is_active, :boolean, default: true)
    field(:is_default, :boolean, default: false)
    field(:settings, :map, default: %{})

    # Virtual fields for decrypted credentials
    field(:api_key, :string, virtual: true)
    field(:access_token, :string, virtual: true)
    field(:refresh_token, :string, virtual: true)
    field(:account_id, :string, virtual: true)
    field(:client_id, :string, virtual: true)
    field(:client_secret, :string, virtual: true)
    field(:tenant_id, :string, virtual: true)
    field(:teams_user_id, :string, virtual: true)

    belongs_to(:user, Tymeslot.DatabaseSchemas.UserSchema)

    timestamps()
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
      :is_active,
      :is_default,
      :settings,
      :user_id
    ])
    |> validate_required([:name, :provider, :user_id])
    |> validate_inclusion(
      :provider,
      ProviderConfig.provider_constraint_list()
    )
    |> validate_provider_specific_fields()
    |> encrypt_credentials()
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Sets this integration as the default, unsetting any other defaults for the user.
  """
  @spec set_as_default_changeset(t()) :: Ecto.Changeset.t()
  def set_as_default_changeset(video_integration) do
    change(video_integration, is_default: true)
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
    e ->
      require Logger

      Logger.error(
        "Failed to decrypt #{field} for video integration #{id}: #{Exception.message(e)}"
      )

      nil
  end

  # Private functions

  defp validate_provider_specific_fields(changeset) do
    provider = get_field(changeset, :provider)

    case provider do
      "mirotalk" ->
        changeset
        |> validate_required([:base_url, :api_key])
        |> URLValidator.validate_url(:base_url)

      "teams" ->
        validate_required(changeset, [:tenant_id, :client_id, :client_secret, :teams_user_id])

      "google_meet" ->
        validate_required(changeset, [:access_token, :refresh_token])

      "custom" ->
        changeset
        |> validate_required([:custom_meeting_url])
        |> URLValidator.validate_url(:custom_meeting_url)

      _ ->
        changeset
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
