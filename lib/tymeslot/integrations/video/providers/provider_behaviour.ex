defmodule Tymeslot.Integrations.Video.Providers.ProviderBehaviour do
  @moduledoc """
  Behaviour for video conferencing provider implementations (MiroTalk, Zoom, Google Meet, etc.).

  This defines the contract that all video providers must implement to enable
  seamless switching between different video conferencing platforms.
  """

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
  """
  @callback capabilities() :: map()

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
end
