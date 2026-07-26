defmodule Tymeslot.Integrations.Video.Providers.ProviderBehaviour do
  @moduledoc """
  Behaviour for video conferencing provider implementations (MiroTalk, Google Meet, etc.).

  This defines the contract that all video providers must implement to enable
  seamless switching between different video conferencing platforms.
  """

  alias Tymeslot.Integrations.Video.Providers.Capabilities

  @doc """
  Creates a new meeting room.

  Returns {:ok, room_data} where room_data contains platform-specific information
  about the created room, or {:error, reason} on failure.
  """
  @callback create_meeting_room(config :: map()) :: {:ok, map()} | {:error, any()}

  @doc """
  Creates a join URL for a participant.

  ## Parameters
    - room_data: Platform-specific room information from create_meeting_room
    - participant_name: Name of the participant
    - participant_email: Email of the participant
    - role: Role of the participant ("organizer", "attendee", "host", etc.)
    - meeting_time: Scheduled meeting time for expiration/validation

  Returns {:ok, join_url} or {:error, reason}.
  """
  @callback create_join_url(
              room_data :: map(),
              participant_name :: String.t(),
              participant_email :: String.t(),
              role :: String.t(),
              meeting_time :: DateTime.t()
            ) :: {:ok, String.t()} | {:error, any()}

  @doc """
  Extracts room identifier from a meeting URL.

  Different platforms use different URL structures, so this normalizes
  the process of extracting the room/meeting ID.

  Returns room_id as string or nil if invalid.
  """
  @callback extract_room_id(meeting_url :: String.t()) :: String.t() | nil

  @doc """
  Validates if a URL is a valid meeting URL for this provider.

  Returns true if the URL is valid for this provider, false otherwise.
  """
  @callback valid_meeting_url?(meeting_url :: String.t()) :: boolean()

  @doc """
  Tests the connection to the video service.

  Returns {:ok, message} on success or {:error, reason} on failure.
  """
  @callback test_connection(config :: map()) :: {:ok, String.t()} | {:error, any()}

  @doc """
  Returns the provider type identifier.
  """
  @callback provider_type() :: atom()

  @doc """
  Returns the display name for this provider.
  """
  @callback display_name() :: String.t()

  @doc """
  Returns the configuration schema for this provider.
  """
  @callback config_schema() :: map()

  @doc """
  Validates the provider configuration.
  """
  @callback validate_config(config :: map()) :: :ok | {:error, String.t()}

  @doc """
  Returns provider-specific capabilities.

  This helps the system understand what features the provider supports
  (e.g., recording, screen sharing, waiting rooms, etc.).

  The keys are a closed vocabulary declared by
  `Tymeslot.Integrations.Video.Providers.Capabilities`. Build the map with
  `Capabilities.new!/1` from a module attribute so an unknown or missing key
  fails at compile time: `ProviderRegistry.providers_with_capability/1` reads
  the map with `Map.get/3`, so a misspelt key is indistinguishable from an
  unsupported feature.
  """
  @callback capabilities() :: Capabilities.t()

  @doc """
  Handles provider-specific meeting lifecycle events.

  ## Parameters
    - event: The lifecycle event (:created, :started, :ended, :cancelled)
    - room_data: Platform-specific room information
    - additional_data: Any additional context data

  Returns :ok or {:error, reason}.
  """
  @callback handle_meeting_event(
              event :: atom(),
              room_data :: map(),
              additional_data :: map()
            ) :: :ok | {:error, any()}

  @doc """
  Generates meeting metadata for email templates and UI display.

  Returns a map with standardized meeting information that can be used
  across different providers in email templates, calendar invites, etc.
  """
  @callback generate_meeting_metadata(room_data :: map()) :: map()

  @doc """
  Updates an existing meeting room on the provider's side after the
  underlying booking changes (e.g. on reschedule).

  ## Parameters
    - room_id: Provider-specific identifier returned by `create_meeting_room/1`.
    - config: The same provider config used to create the room, merged with
      the new meeting attributes (`meeting_topic`, `meeting_start_time`,
      `meeting_end_time`).

  Note: callers invoke `Rooms.update_meeting_room/2` with `:topic`,
  `:start_time`, and `:end_time` opts. The `Rooms` layer renames these to
  `:meeting_topic`, `:meeting_start_time`, and `:meeting_end_time` before
  passing `config` here, so provider implementations should read the renamed
  keys directly from `config`.

  Providers that don't have a server-side meeting object (e.g. Google Meet,
  MiroTalk, Custom) should return `:ok` without performing any action.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @callback update_meeting_room(room_id :: String.t(), config :: map()) ::
              :ok | {:error, any()}

  @doc """
  Deletes a meeting room on the provider's side (e.g. on cancellation).

  ## Parameters
    - room_id: Provider-specific identifier returned by `create_meeting_room/1`.
    - config: The same provider config used to create the room.

  Providers that don't have a server-side meeting object should return `:ok`
  without performing any action. A "not found" response from the provider
  should also resolve to `:ok` so cancellation is idempotent.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @callback delete_meeting_room(room_id :: String.t(), config :: map()) ::
              :ok | {:error, any()}

  @doc """
  Builds the runtime config map this provider expects in `create_meeting_room/1`,
  `test_connection/1`, etc.

  Receives the persisted integration record, its decrypted credentials, and any
  call-site options (e.g. `meeting_id` for the custom provider). The provider
  knows which fields it needs — the dispatcher (`Connection`, `Rooms`) just
  delegates here.
  """
  @callback build_config(
              integration :: struct(),
              decrypted :: map(),
              opts :: keyword()
            ) :: map()

  @doc """
  Declares the provider-specific changeset validation rules used by
  `VideoIntegrationSchema`. Pure data; the schema interprets it.

    * `:required` — fields that must be present
    * `:credential_pairs` — `{virtual_field, encrypted_field}` pairs where the
      virtual field is required only when the encrypted counterpart is absent
    * `:url_fields` — fields to URL-validate (with `block_private_ips: true`)
  """
  @callback credential_spec() :: %{
              required: [atom()],
              credential_pairs: [{atom(), atom()}],
              url_fields: [atom()]
            }

  @doc """
  Substrings that identify a meeting URL as belonging to this provider.

  Used by `ProviderAdapter.detect_provider_from_url/1` to dispatch URL
  extraction to the right provider. Return `[]` (or omit) for providers
  whose URLs are arbitrary user-supplied links (e.g. custom).
  """
  @callback url_patterns() :: [String.t()]

  @optional_callbacks update_meeting_room: 2, delete_meeting_room: 2, url_patterns: 0
end
