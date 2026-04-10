defmodule Tymeslot.Integrations.Calendar.CalendarIntegrationSchema do
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
          provider_account_id: String.t() | nil,
          provider_account_email: String.t() | nil,
          sync_error: String.t() | nil,
          google_channel_id: String.t() | nil,
          google_channel_resource_id: String.t() | nil,
          google_channel_expires_at: DateTime.t() | nil,
          google_channel_secret: String.t() | nil,
          google_sync_token: String.t() | nil,
          last_google_notification_at: DateTime.t() | nil,
          graph_subscription_id: String.t() | nil,
          graph_subscription_expires_at: DateTime.t() | nil,
          graph_client_state: String.t() | nil,
          graph_delta_link: String.t() | nil,
          last_outlook_notification_at: DateTime.t() | nil,
          caldav_sync_tier: integer() | nil,
          caldav_sync_token: String.t() | nil,
          last_external_sync_at: DateTime.t() | nil,
          user: Tymeslot.Auth.UserSchema.t() | Ecto.Association.NotLoaded.t(),
          calendar_events:
            [Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema.t()]
            | Ecto.Association.NotLoaded.t(),
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
    field(:provider_account_id, :string)
    field(:provider_account_email, :string)
    field(:sync_error, :string)

    # Google webhook channel fields
    field(:google_channel_id, :string)
    field(:google_channel_resource_id, :string)
    field(:google_channel_expires_at, :utc_datetime)
    # Stored as plaintext: random verification token with no credential reuse risk.
    # Used solely to verify webhook authenticity. Follow _encrypted pattern if threat model changes.
    field(:google_channel_secret, :string)
    field(:google_sync_token, :string)
    field(:last_google_notification_at, :utc_datetime)

    # Outlook subscription fields
    field(:graph_subscription_id, :string)
    field(:graph_subscription_expires_at, :utc_datetime)
    # Stored as plaintext: random verification token with no credential reuse risk.
    # Used solely to verify webhook authenticity. Follow _encrypted pattern if threat model changes.
    field(:graph_client_state, :string)
    field(:graph_delta_link, :string)
    field(:last_outlook_notification_at, :utc_datetime)

    # CalDAV sync fields
    field(:caldav_sync_tier, :integer)
    field(:caldav_sync_token, :string)

    # Integration sync health
    field(:last_external_sync_at, :utc_datetime)

    # Virtual fields for decrypted values
    field(:username, :string, virtual: true)
    field(:password, :string, virtual: true)
    field(:access_token, :string, virtual: true)
    field(:refresh_token, :string, virtual: true)

    belongs_to(:user, Tymeslot.Auth.UserSchema)

    has_many(:calendar_events, Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema,
      foreign_key: :calendar_integration_id
    )

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
      :provider_account_id,
      :provider_account_email,
      :user_id,
      :sync_error
    ])
    |> update_change(:base_url, &PathUtils.ensure_scheme/1)
    |> validate_required([:name, :provider, :user_id])
    |> validate_base_url_for_caldav()
    |> validate_inclusion(
      :provider,
      ProviderConfig.provider_constraint_list()
    )
    |> URLValidator.validate_url(:base_url, block_private_ips: true)
    |> encrypt_credentials()
    |> foreign_key_constraint(:user_id)
    |> check_constraint(:provider, name: :calendar_integrations_provider_check)
    |> unique_constraint([:user_id, :provider, :provider_account_id],
      name: :unique_active_calendar_account_per_user,
      message: "an integration for this account already exists"
    )
    |> unique_constraint([:user_id, :provider],
      name: :unique_active_calendar_null_account_per_user,
      message: "an integration for this provider already exists"
    )
  end

  @caldav_based_providers ~w(caldav radicale nextcloud zimbra)

  defp validate_base_url_for_caldav(changeset) do
    provider = get_field(changeset, :provider)

    if provider in @caldav_based_providers do
      validate_required(changeset, [:base_url])
    else
      changeset
    end
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
