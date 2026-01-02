defmodule Tymeslot.Integrations.Video.Providers.ProviderAdapter do
  @moduledoc """
  Adapter that wraps video provider calls with common functionality.

  This module provides a unified interface for all video providers,
  handling common concerns like error handling, logging, metrics, and
  provider lifecycle management.
  """

  require Logger
  alias Tymeslot.Infrastructure.Metrics
  alias Tymeslot.Integrations.Video.Providers.ProviderRegistry

  @doc """
  Creates a new meeting room using the specified provider.

  Returns {:ok, %{provider_type: atom, room_data: map, provider_module: module}}
  or {:error, reason}.
  """
  @spec create_meeting_room(atom(), map()) :: {:ok, map()} | {:error, term()}
  def create_meeting_room(provider_type, config) do
    Metrics.time_operation(:video_create_room, %{provider: provider_type}, fn ->
      Logger.info("Creating meeting room with #{provider_type} provider")

      with {:ok, provider_module} <- ProviderRegistry.get_provider(provider_type),
           :ok <- provider_module.validate_config(config),
           {:ok, room_data} <- provider_module.create_meeting_room(config) do
        Logger.info("Successfully created meeting room",
          provider: provider_type,
          room_id: extract_room_identifier(room_data)
        )

        # Handle meeting created event
        provider_module.handle_meeting_event(:created, room_data, %{})

        {:ok,
         %{
           provider_type: provider_type,
           room_data: room_data,
           provider_module: provider_module
         }}
      else
        {:error, :unknown_provider} ->
          Logger.error("Unknown video provider", provider_type: provider_type)
          {:error, :unknown_provider}

        {:error, _} = error ->
          Logger.error("Failed to create meeting room with #{provider_type}",
            reason: inspect(error)
          )

          error
      end
    end)
  end

  @doc """
  Creates a join URL for a participant.
  """
  @spec create_join_url(map(), String.t(), String.t(), atom(), DateTime.t()) ::
          {:ok, String.t()} | {:error, term()}
  def create_join_url(meeting_context, participant_name, participant_email, role, meeting_time) do
    %{
      provider_type: provider_type,
      room_data: room_data,
      provider_module: provider_module
    } = meeting_context

    Metrics.time_operation(:video_create_join_url, %{provider: provider_type}, fn ->
      Logger.debug("Creating join URL for participant",
        provider: provider_type,
        participant: participant_name,
        role: role
      )

      case provider_module.create_join_url(
             room_data,
             participant_name,
             participant_email,
             role,
             meeting_time
           ) do
        {:ok, join_url} ->
          Logger.debug("Successfully created join URL",
            provider: provider_type,
            participant: participant_name
          )

          {:ok, join_url}

        {:error, reason} = error ->
          Logger.error("Failed to create join URL",
            provider: provider_type,
            participant: participant_name,
            reason: inspect(reason)
          )

          error
      end
    end)
  end

  @doc """
  Extracts room ID from a meeting URL.
  """
  @spec extract_room_id(String.t()) :: String.t() | nil
  def extract_room_id(meeting_url) do
    # Try to detect provider from URL and extract room ID
    case detect_provider_from_url(meeting_url) do
      {:ok, provider_type} ->
        case ProviderRegistry.get_provider(provider_type) do
          {:ok, provider_module} ->
            provider_module.extract_room_id(meeting_url)

          {:error, _} ->
            Logger.warning("Failed to get provider for room ID extraction",
              provider_type: provider_type
            )

            nil
        end

      {:error, _} ->
        Logger.warning("Could not detect provider from URL", url: meeting_url)
        nil
    end
  end

  @doc """
  Validates if a URL is a valid meeting URL.
  """
  @spec valid_meeting_url?(String.t()) :: boolean()
  def valid_meeting_url?(meeting_url) do
    case detect_provider_from_url(meeting_url) do
      {:ok, provider_type} ->
        case ProviderRegistry.get_provider(provider_type) do
          {:ok, provider_module} ->
            provider_module.valid_meeting_url?(meeting_url)

          {:error, _} ->
            false
        end

      {:error, _} ->
        false
    end
  end

  @doc """
  Tests connection to a video provider.
  """
  @spec test_connection(atom(), map()) :: {:ok, String.t()} | {:error, term()}
  def test_connection(provider_type, config) do
    Logger.info("Testing connection to #{provider_type} provider")

    case ProviderRegistry.test_provider_connection(provider_type, config) do
      {:ok, message} ->
        Logger.info("Connection test successful", provider: provider_type)
        {:ok, message}

      {:error, reason} = error ->
        Logger.error("Connection test failed",
          provider: provider_type,
          reason: inspect(reason)
        )

        error
    end
  end

  @doc """
  Handles meeting lifecycle events.
  """
  @spec handle_meeting_event(map(), atom(), map()) :: :ok | {:error, term()}
  def handle_meeting_event(meeting_context, event, additional_data \\ %{}) do
    %{
      provider_type: provider_type,
      room_data: room_data,
      provider_module: provider_module
    } = meeting_context

    Logger.info("Handling meeting event",
      provider: provider_type,
      event: event,
      room_id: extract_room_identifier(room_data)
    )

    case provider_module.handle_meeting_event(event, room_data, additional_data) do
      :ok ->
        Logger.debug("Successfully handled meeting event",
          provider: provider_type,
          event: event
        )

        :ok

      {:error, reason} = error ->
        Logger.error("Failed to handle meeting event",
          provider: provider_type,
          event: event,
          reason: inspect(reason)
        )

        error
    end
  end

  @doc """
  Generates meeting metadata for display purposes.
  """
  @spec generate_meeting_metadata(map()) :: map()
  def generate_meeting_metadata(meeting_context) do
    %{
      provider_type: provider_type,
      room_data: room_data,
      provider_module: provider_module
    } = meeting_context

    base_metadata = provider_module.generate_meeting_metadata(room_data)

    Map.merge(base_metadata, %{
      provider_type: provider_type,
      provider_name: provider_module.display_name()
    })
  end

  # Private helper functions

  defp detect_provider_from_url(meeting_url) when is_binary(meeting_url) do
    provider_patterns = [
      {["mirotalk", "talk."], :mirotalk},
      {["meet.google.com"], :google_meet},
      {["teams.microsoft.com"], :teams},
      {["webex.com"], :webex},
      {["meet.jit.si"], :jitsi},
      {["whereby.com"], :whereby}
    ]

    case find_matching_provider(meeting_url, provider_patterns) do
      {:ok, provider} -> {:ok, provider}
      :not_found -> {:error, "Unknown provider"}
    end
  end

  defp detect_provider_from_url(_), do: {:error, "Invalid URL"}

  defp find_matching_provider(meeting_url, provider_patterns) do
    Enum.find_value(provider_patterns, :not_found, fn {patterns, provider} ->
      if Enum.any?(patterns, &String.contains?(meeting_url, &1)) do
        {:ok, provider}
      else
        nil
      end
    end)
  end

  defp extract_room_identifier(room_data) when is_map(room_data) do
    # Try common room identifier keys
    room_data[:room_id] ||
      room_data[:meeting_id] ||
      room_data[:id] ||
      room_data["room_id"] ||
      room_data["meeting_id"] ||
      room_data["id"] ||
      "unknown"
  end

  defp extract_room_identifier(_), do: "unknown"
end
