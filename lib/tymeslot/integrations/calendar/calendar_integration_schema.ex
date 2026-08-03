defmodule Tymeslot.Integrations.Calendar.CalendarIntegrationSchema do
  @moduledoc """
  Schema for calendar integrations.

  Supports multiple calendar providers:
  - CalDAV: Generic CalDAV servers (SabreDAV, Baikal, etc.)
  - Radicale: Lightweight CalDAV server with simple paths
  - Nextcloud: Nextcloud/ownCloud with remote.php/dav endpoint
  - Google: Google Calendar with OAuth
  - Outlook: Microsoft Outlook Calendar with OAuth
  - ICS subscription: a published iCalendar feed, read-only

  A subscription's feed URL lives in `subscription_url_encrypted`, not in
  `base_url`, because for this provider the URL *is* the credential: Google's
  "secret address in iCal format" and Outlook's published link grant anyone
  holding them full read access to the calendar. `base_url` carries only the
  feed's origin, which is what the dashboard renders.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Tymeslot.ChangesetValidators.URL, as: URLValidator
  alias Tymeslot.Integrations.Calendar.CalendarEntry
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
          subscription_url_encrypted: binary() | nil,
          token_expires_at: DateTime.t() | nil,
          oauth_scope: String.t() | nil,
          calendar_paths: [String.t()],
          calendar_list: [CalendarEntry.t()],
          default_booking_calendar_id: String.t() | nil,
          verify_ssl: boolean(),
          is_active: boolean(),
          needs_reauth: boolean(),
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
          last_full_sync_at: DateTime.t() | nil,
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
    field(:subscription_url_encrypted, :binary)
    field(:token_expires_at, :utc_datetime)
    field(:oauth_scope, :string)
    field(:calendar_paths, {:array, :string}, default: [])
    field(:calendar_list, {:array, CalendarEntry}, default: [])
    field(:default_booking_calendar_id, :string)
    field(:verify_ssl, :boolean, default: true)
    field(:is_active, :boolean, default: true)
    field(:needs_reauth, :boolean, default: false)
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
    field(:last_full_sync_at, :utc_datetime)

    # Virtual fields for decrypted values
    field(:username, :string, virtual: true, redact: true)
    field(:password, :string, virtual: true, redact: true)
    field(:access_token, :string, virtual: true, redact: true)
    field(:refresh_token, :string, virtual: true, redact: true)
    field(:subscription_url, :string, virtual: true, redact: true)

    belongs_to(:user, Tymeslot.Auth.UserSchema)

    has_many(:calendar_events, Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema,
      foreign_key: :calendar_integration_id
    )

    timestamps(type: :utc_datetime)
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
      :subscription_url,
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
    |> update_change(:base_url, &PathUtils.normalize_base_url/1)
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

  # Read at runtime rather than bound into a module attribute: the list is only
  # ever used inside this function body, never in a guard, so compile-time
  # binding buys nothing and costs a compile-time dependency on
  # `ProviderConfig` — one of the edges `mix xref --label compile-connected`
  # caps.
  defp validate_base_url_for_caldav(changeset) do
    provider = get_field(changeset, :provider)

    if provider in ProviderConfig.caldav_based_provider_strings() do
      validate_required(changeset, [:base_url])
    else
      changeset
    end
  end

  @doc """
  Decrypts the username and password fields.
  Also decrypts OAuth tokens and a subscription feed URL if present.
  """
  @spec decrypt_credentials(t()) :: t()
  def decrypt_credentials(%__MODULE__{} = integration) do
    %{
      integration
      | username: Encryption.decrypt(integration.username_encrypted),
        password: Encryption.decrypt(integration.password_encrypted),
        access_token: Encryption.decrypt(integration.access_token_encrypted),
        refresh_token: Encryption.decrypt(integration.refresh_token_encrypted),
        subscription_url: Encryption.decrypt(integration.subscription_url_encrypted)
    }
  end

  @doc """
  Converts a persisted integration into the plain, atom-keyed config map that
  the CalDAV-family `Provider.perform_connection_test/1` callbacks read.

  The struct itself cannot be passed: those callbacks read their config with
  bracket access, which structs do not support. A plain map supports both
  bracket and dot access, so this is the one shape every CalDAV-family
  provider callback can consume. This is `Calendar.Connection.probe/3`'s only
  caller of `to_provider_config/1`, and that path deliberately never calls
  `validate_config/1` (see its moduledoc), so only what `perform_connection_test/1`
  itself reads across all seven CalDAV-family providers needs to survive the
  conversion: `:base_url`, `:username`, `:password`, `:calendar_paths`, and
  `:provider`.

  Unlike `Map.from_struct/1`, this never carries the `*_encrypted` ciphertext
  fields or any other schema field across, so a crash report generated while
  handling the resulting map can't print more than a CalDAV connection test
  ever needed.

  Callers must decrypt credentials first (see `decrypt_credentials/1`); this
  function does not decrypt.
  """
  @spec to_provider_config(t()) :: map()
  def to_provider_config(%__MODULE__{} = integration) do
    %{
      base_url: integration.base_url,
      username: integration.username,
      password: integration.password,
      calendar_paths: integration.calendar_paths || [],
      provider: integration.provider
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

  @encrypted_credential_fields [
    :username_encrypted,
    :password_encrypted,
    :access_token_encrypted,
    :refresh_token_encrypted,
    :subscription_url_encrypted
  ]

  @doc """
  Returns the list of encrypted credential field atoms on this schema. Used by
  `decryption_status/1` and `CalendarIntegrationQueries.maybe_clear_needs_reauth/1`
  so the authoritative list lives in one place.
  """
  @spec encrypted_credential_fields() :: [atom()]
  def encrypted_credential_fields, do: @encrypted_credential_fields

  @doc """
  Reports whether any encrypted credential on the integration fails to decrypt
  under the current keyring. Returns `:ok` when every ciphertext is either
  absent or decryptable, `:requires_reencryption` otherwise.

  Used by sync workers to short-circuit jobs when SECRET_KEY_BASE has been
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

  defp encrypt_credentials(changeset) do
    changeset
    |> encrypt_field(:username, :username_encrypted)
    |> encrypt_field(:password, :password_encrypted)
    |> encrypt_field(:access_token, :access_token_encrypted)
    |> encrypt_field(:refresh_token, :refresh_token_encrypted)
    |> encrypt_field(:subscription_url, :subscription_url_encrypted)
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
