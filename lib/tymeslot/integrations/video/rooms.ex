defmodule Tymeslot.Integrations.Video.Rooms do
  @moduledoc """
  Meeting room operations for video integrations.

  Provides APIs to create meeting rooms, generate join URLs, handle lifecycle events,
  and generate standardized metadata. Delegates provider-specific work to the
  Providers layer via the ProviderAdapter.
  """

  require Logger
  alias Tymeslot.DatabaseQueries.VideoIntegrationQueries
  alias Tymeslot.DatabaseSchemas.VideoIntegrationSchema
  alias Tymeslot.Infrastructure.Metrics
  alias Tymeslot.Integrations.Video.Providers.ProviderAdapter

  @doc """
  Creates a new meeting room using the configured provider for a user.

  Returns {:ok, meeting_context} or {:error, reason}.
  The meeting_context contains provider-specific room data and metadata.
  """
  @spec create_meeting_room(pos_integer() | nil) :: {:ok, map()} | {:error, any()}
  def create_meeting_room(user_id \\ nil) do
    Metrics.time_operation(:video_create_meeting_room, %{}, fn ->
      Logger.info("Creating meeting room for user", user_id: user_id)
      do_create_meeting_room(user_id)
    end)
  end

  defp do_create_meeting_room(user_id) do
    case get_provider_config(user_id) do
      {:ok, provider_type, config} ->
        create_room_with_provider(provider_type, config)

      {:error, reason} = error ->
        Logger.error("Failed to get provider configuration", reason: inspect(reason))
        error
    end
  end

  defp create_room_with_provider(provider_type, config) do
    Logger.info("Using #{provider_type} provider for meeting room creation")

    case ProviderAdapter.create_meeting_room(provider_type, config) do
      {:ok, meeting_context} ->
        updated_context = add_provider_config_to_context(meeting_context, config)

        Logger.info("Successfully created meeting room",
          provider: provider_type,
          room_id: extract_room_id(updated_context)
        )

        {:ok, updated_context}

      {:error, reason} = error ->
        Logger.error("Failed to create meeting room",
          provider: provider_type,
          reason: inspect(reason)
        )

        error
    end
  end

  defp add_provider_config_to_context(meeting_context, config) do
    update_in(meeting_context.room_data, fn room_data ->
      Map.put(room_data, :provider_config, config)
    end)
  end

  @doc """
  Creates a join URL for a meeting participant.
  """
  @spec create_join_url(map(), String.t(), String.t(), String.t(), DateTime.t()) ::
          {:ok, String.t()} | {:error, any()}
  def create_join_url(meeting_context, participant_name, participant_email, role, meeting_time) do
    Metrics.time_operation(
      :video_create_join_url,
      %{
        provider: meeting_context.provider_type
      },
      fn ->
        Logger.info("Creating join URL for participant",
          participant: participant_name,
          role: role,
          provider: meeting_context.provider_type
        )

        case ProviderAdapter.create_join_url(
               meeting_context,
               participant_name,
               participant_email,
               role,
               meeting_time
             ) do
          {:ok, _join_url} = result ->
            Logger.info("Successfully created join URL",
              participant: participant_name,
              provider: meeting_context.provider_type
            )

            result

          {:error, reason} = error ->
            Logger.error("Failed to create join URL",
              participant: participant_name,
              provider: meeting_context.provider_type,
              reason: inspect(reason)
            )

            error
        end
      end
    )
  end

  @doc """
  Handles meeting lifecycle events.
  """
  @spec handle_meeting_event(map(), atom(), map()) :: :ok | {:error, any()}
  def handle_meeting_event(meeting_context, event, additional_data \\ %{}) do
    Logger.info("Handling meeting event",
      event: event,
      provider: meeting_context.provider_type,
      room_id: extract_room_id(meeting_context)
    )

    case ProviderAdapter.handle_meeting_event(meeting_context, event, additional_data) do
      :ok ->
        Logger.debug("Successfully handled meeting event",
          event: event,
          provider: meeting_context.provider_type
        )

        :ok

      {:error, reason} = error ->
        Logger.error("Failed to handle meeting event",
          event: event,
          provider: meeting_context.provider_type,
          reason: inspect(reason)
        )

        error
    end
  end

  @doc """
  Generates meeting metadata for display or emails.
  """
  @spec generate_meeting_metadata(map()) :: map()
  def generate_meeting_metadata(meeting_context) do
    Logger.debug("Generating meeting metadata",
      provider: meeting_context.provider_type,
      room_id: extract_room_id(meeting_context)
    )

    ProviderAdapter.generate_meeting_metadata(meeting_context)
  end

  # Private helpers
  defp extract_room_id(meeting_context) do
    meeting_context.room_data[:room_id] || meeting_context.room_data["room_id"] || "unknown"
  end

  defp get_provider_config(user_id) do
    case get_integration_from_database(user_id) do
      {:ok, integration} ->
        decrypted = VideoIntegrationSchema.decrypt_credentials(integration)

        provider_type =
          try do
            String.to_existing_atom(integration.provider)
          rescue
            ArgumentError -> :unknown
          end

        config =
          case provider_type do
            :mirotalk ->
              %{
                api_key: decrypted.api_key,
                base_url: integration.base_url
              }

            :google_meet ->
              %{
                access_token: decrypted.access_token,
                refresh_token: decrypted.refresh_token,
                token_expires_at: integration.token_expires_at,
                oauth_scope: integration.oauth_scope,
                integration_id: integration.id,
                user_id: integration.user_id
              }

            :teams ->
              %{
                access_token: decrypted.access_token,
                refresh_token: decrypted.refresh_token,
                token_expires_at: integration.token_expires_at,
                integration_id: integration.id,
                user_id: integration.user_id
              }

            :none ->
              %{}

            _ ->
              %{}
          end

        {:ok, provider_type, config}

      :not_found ->
        {:error,
         "No video integration configured. Please add a video integration in the dashboard."}

      {:error, :user_id_required} ->
        {:error, :user_id_required}
    end
  end

  defp get_integration_from_database(user_id) do
    case user_id do
      nil ->
        {:error, :user_id_required}

      user_id ->
        case VideoIntegrationQueries.get_default_for_user(user_id) do
          {:ok, integration} -> {:ok, integration}
          {:error, :not_found} -> :not_found
        end
    end
  end
end
