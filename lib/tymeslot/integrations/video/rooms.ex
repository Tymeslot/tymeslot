defmodule Tymeslot.Integrations.Video.Rooms do
  @moduledoc """
  Meeting room operations for video integrations.

  Provides APIs to create meeting rooms, generate join URLs, handle lifecycle events,
  and generate standardized metadata. Delegates provider-specific work to the
  Providers layer via the ProviderAdapter.
  """

  require Logger
  alias Tymeslot.Infrastructure.Metrics
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.Providers.ProviderAdapter
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema

  @doc """
  Creates a new meeting room using the configured provider for a user.

  Returns {:ok, meeting_context} or {:error, reason}.
  The meeting_context contains provider-specific room data and metadata.
  """
  @spec create_meeting_room(pos_integer() | nil, keyword()) :: {:ok, map()} | {:error, any()}
  def create_meeting_room(user_id \\ nil, opts \\ []) do
    Metrics.time_operation(:video_create_meeting_room, %{}, fn ->
      Logger.info("Creating meeting room for user", user_id: user_id)
      do_create_meeting_room(user_id, opts)
    end)
  end

  defp do_create_meeting_room(user_id, opts) do
    case get_provider_config(user_id, opts) do
      {:ok, provider_type, config} ->
        create_room_with_provider(provider_type, config)

      {:error, reason} = error ->
        Logger.error("Failed to get provider configuration", reason: inspect(reason))
        error
    end
  end

  defp create_room_with_provider(provider_type, config) do
    Logger.info("Using provider for meeting room creation", provider_type: provider_type)

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
  Updates a meeting room on the provider's side after the underlying
  booking changes (e.g. on reschedule).

  Looks up the provider for `integration_id`, merges the meeting attributes
  into the provider config, then dispatches to the provider's
  `update_meeting_room/2` callback. Providers without a server-side meeting
  object (Google Meet, MiroTalk, Custom) silently succeed.

  ## Required opts
    - `:integration_id` — the video integration that owns the room
    - `:room_id` — provider-specific room identifier

  ## Optional opts
    - `:topic`, `:start_time`, `:end_time` — new meeting attributes
  """
  @spec update_meeting_room(pos_integer() | nil, keyword()) :: :ok | {:error, any()}
  def update_meeting_room(user_id, opts) do
    Metrics.time_operation(:video_update_meeting_room, %{}, fn ->
      with {:ok, room_id} <- fetch_required_opt(opts, :room_id),
           {:ok, provider_type, config} <- get_provider_config(user_id, opts) do
        ProviderAdapter.update_meeting_room(
          provider_type,
          room_id,
          merge_meeting_attrs(config, opts)
        )
      end
    end)
  end

  @doc """
  Deletes a meeting room on the provider's side (e.g. on cancellation).

  Looks up the provider for `integration_id`, dispatches to the provider's
  `delete_meeting_room/2` callback. Providers without a server-side meeting
  object silently succeed. A "not found" response from the provider also
  resolves to `:ok` so cancellation is idempotent.

  ## Required opts
    - `:integration_id` — the video integration that owns the room
    - `:room_id` — provider-specific room identifier
  """
  @spec delete_meeting_room(pos_integer() | nil, keyword()) :: :ok | {:error, any()}
  def delete_meeting_room(user_id, opts) do
    Metrics.time_operation(:video_delete_meeting_room, %{}, fn ->
      with {:ok, room_id} <- fetch_required_opt(opts, :room_id),
           {:ok, provider_type, config} <- get_provider_config(user_id, opts) do
        ProviderAdapter.delete_meeting_room(provider_type, room_id, config)
      end
    end)
  end

  defp fetch_required_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, {:missing_required_opt, key}}
      "" -> {:error, {:missing_required_opt, key}}
      value -> {:ok, value}
    end
  end

  defp merge_meeting_attrs(config, opts) do
    config
    |> maybe_put(:meeting_topic, Keyword.get(opts, :topic))
    |> maybe_put(:meeting_start_time, Keyword.get(opts, :start_time))
    |> maybe_put(:meeting_end_time, Keyword.get(opts, :end_time))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
          {:ok, _url} = result ->
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

  defp get_provider_config(user_id, opts) do
    case get_integration_from_database(user_id, opts) do
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
                oauth_scope: integration.oauth_scope,
                tenant_id: decrypted.tenant_id,
                integration_id: integration.id,
                user_id: integration.user_id
              }

            :zoom ->
              %{
                access_token: decrypted.access_token,
                refresh_token: decrypted.refresh_token,
                token_expires_at: integration.token_expires_at,
                oauth_scope: integration.oauth_scope,
                integration_id: integration.id,
                user_id: integration.user_id
              }

            :custom ->
              %{
                custom_meeting_url: integration.custom_meeting_url,
                meeting_id: Keyword.get(opts, :meeting_id)
              }

            :none ->
              %{}

            _other_provider ->
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

  defp get_integration_from_database(user_id, opts) do
    case user_id do
      nil ->
        {:error, :user_id_required}

      user_id ->
        case Keyword.get(opts, :integration_id) do
          nil ->
            :not_found

          integration_id ->
            case Video.fetch_integration_for_user(integration_id, user_id) do
              {:ok, integration} -> {:ok, integration}
              {:error, :not_found} -> :not_found
            end
        end
    end
  end
end
