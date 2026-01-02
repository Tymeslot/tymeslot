defmodule Tymeslot.DatabaseSchemas.CalendarIntegrationSchema do
  @moduledoc """
  Schema for calendar integrations.

  Supports multiple calendar providers:
  - CalDAV: Generic CalDAV servers (SabreDAV, Baikal, etc.)
  - Radicale: Lightweight CalDAV server with simple paths
  - Nextcloud: Nextcloud/ownCloud with remote.php/dav endpoint
  - Google: Google Calendar with OAuth
  - Outlook: Microsoft Outlook Calendar with OAuth
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Tymeslot.ChangesetValidators.URL, as: URLValidator
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Shared.PathUtils
  alias Tymeslot.Security.Encryption

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer() | nil,
          name: String.t() | nil,
          provider: String.t(),
          base_url: String.t() | nil,
          username_encrypted: binary() | nil,
          password_encrypted: binary() | nil,
          access_token_encrypted: binary() | nil,
          refresh_token_encrypted: binary() | nil,
          token_expires_at: DateTime.t() | nil,
          oauth_scope: String.t() | nil,
          calendar_paths: [String.t()],
          calendar_list: [map()],
          default_booking_calendar_id: String.t() | nil,
          verify_ssl: boolean(),
          is_active: boolean(),
          last_sync_at: DateTime.t() | nil,
          sync_error: String.t() | nil,
          user: Tymeslot.DatabaseSchemas.UserSchema.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "calendar_integrations" do
    field(:name, :string)
    field(:provider, :string, default: "caldav")
    field(:base_url, :string)
    field(:username_encrypted, :binary)
    field(:password_encrypted, :binary)
    field(:access_token_encrypted, :binary)
    field(:refresh_token_encrypted, :binary)
    field(:token_expires_at, :utc_datetime)
    field(:oauth_scope, :string)
    field(:calendar_paths, {:array, :string}, default: [])
    field(:calendar_list, {:array, :map}, default: [])
    field(:default_booking_calendar_id, :string)
    field(:verify_ssl, :boolean, default: true)
    field(:is_active, :boolean, default: true)
    field(:last_sync_at, :utc_datetime)
    field(:sync_error, :string)

    # Virtual fields for decrypted values
    field(:username, :string, virtual: true)
    field(:password, :string, virtual: true)
    field(:access_token, :string, virtual: true)
    field(:refresh_token, :string, virtual: true)

    belongs_to(:user, Tymeslot.DatabaseSchemas.UserSchema)

    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(calendar_integration, attrs) do
    calendar_integration
    |> cast(attrs, [
      :name,
      :provider,
      :base_url,
      :username,
      :password,
      :access_token,
      :refresh_token,
      :token_expires_at,
      :oauth_scope,
      :calendar_paths,
      :calendar_list,
      :default_booking_calendar_id,
      :verify_ssl,
      :is_active,
      :user_id,
      :sync_error
    ])
    |> update_change(:base_url, &PathUtils.ensure_scheme/1)
    |> validate_required([:name, :provider, :base_url, :user_id])
    |> validate_inclusion(
      :provider,
      ProviderConfig.provider_constraint_list()
    )
    |> URLValidator.validate_url(:base_url)
    |> encrypt_credentials()
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:default_booking_calendar_id,
      name: :unique_booking_calendar_per_user
    )
  end

  @doc """
  Decrypts the username and password fields.
  Also decrypts OAuth tokens if present.
  """
  @spec decrypt_credentials(t()) :: t()
  def decrypt_credentials(%__MODULE__{} = integration) do
    %{
      integration
      | username: Encryption.decrypt(integration.username_encrypted),
        password: Encryption.decrypt(integration.password_encrypted),
        access_token: Encryption.decrypt(integration.access_token_encrypted),
        refresh_token: Encryption.decrypt(integration.refresh_token_encrypted)
    }
  end

  @doc """
  Decrypts the OAuth token fields.
  """
  @spec decrypt_oauth_tokens(t()) :: t()
  def decrypt_oauth_tokens(%__MODULE__{} = integration) do
    %{
      integration
      | access_token: Encryption.decrypt(integration.access_token_encrypted),
        refresh_token: Encryption.decrypt(integration.refresh_token_encrypted)
    }
  end

  # Private functions

  defp encrypt_credentials(changeset) do
    changeset
    |> encrypt_field(:username, :username_encrypted)
    |> encrypt_field(:password, :password_encrypted)
    |> encrypt_field(:access_token, :access_token_encrypted)
    |> encrypt_field(:refresh_token, :refresh_token_encrypted)
  end

  defp encrypt_field(changeset, virtual_field, encrypted_field) do
    case get_change(changeset, virtual_field) do
      nil ->
        changeset

      value ->
        changeset
        |> put_change(encrypted_field, Encryption.encrypt(value))
        |> delete_change(virtual_field)
    end
  end
end
