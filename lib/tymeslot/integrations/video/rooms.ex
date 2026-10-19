defmodule Tymeslot.Integrations.Video.Rooms do
  @moduledoc """
  Meeting room operations for video integrations.

  Provides APIs to create, update and delete meeting rooms and to generate join
  URLs. Delegates provider-specific work to the Providers layer via the
  ProviderAdapter.

  It logs and times nothing itself: `ProviderAdapter` and the providers log
  and time each call, and the caller logs a failure once, with the booking or
  event it was for.
  """

  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.MeetingContext
  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Integrations.Video.Providers.ProviderAdapter
  alias Tymeslot.Integrations.Video.RoomCreationError
  alias Tymeslot.Integrations.Video.RoomData
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema

  @doc """
  Creates a new meeting room using the configured provider for a user.

  Returns {:ok, meeting_context} or {:error, reason}.
  The meeting_context contains provider-specific room data and metadata.

  ## Optional opts
    - `:event_details` — the `Tymeslot.Integrations.Video.EventDetails` the
      room is for, its title and times
    - `:calendar_event_id`: the calendar event the room is for (a booking's
      or a calendar grid event's), for a provider that can host the meeting on
      it (Teams on the same Microsoft account) instead of creating an event of
      its own
  """
  # The outcome is kept on the integration: a refusal its server will repeat
  # for every booking is recorded for the owner, and a created room clears one.
  # A failure is the caller's to log, once, with the booking or event it was
  # for; `ProviderAdapter` and the provider log what happened on the wire.
  @spec create_meeting_room(pos_integer() | nil, keyword()) ::
          {:ok, MeetingContext.t()} | {:error, any()}
  def create_meeting_room(user_id, opts \\ []) do
    with {:ok, integration, provider_type, config} <- resolve_integration(user_id, opts) do
      config =
        config
        |> maybe_attach_event_details(opts)
        |> maybe_put(:calendar_event_id, Keyword.get(opts, :calendar_event_id))

      result = create_room_with_provider(provider_type, config)
      RoomCreationError.track(integration, result)
      result
    end
  end

  defp maybe_attach_event_details(config, opts) do
    case Keyword.get(opts, :event_details) do
      details when is_map(details) -> Map.put(config, :event_details, details)
      _other -> config
    end
  end

  defp create_room_with_provider(provider_type, config) do
    with {:ok, meeting_context} <- ProviderAdapter.create_meeting_room(provider_type, config) do
      {:ok, add_provider_config_to_context(meeting_context, config)}
    end
  end

  defp add_provider_config_to_context(meeting_context, config) do
    update_in(meeting_context.room_data, fn room_data ->
      %{room_data | provider_config: config}
    end)
  end

  @doc """
  How long creating a room on the integration `integration_id` of `user_id`
  can wait on the provider's network, in milliseconds (see
  `ProviderConfig.room_creation_budget_ms/1`).

  When the integration cannot be resolved, creation fails before any request,
  but the budget answered is still the largest any provider declares, so a
  caller never waits less than a creation could take.
  """
  @spec room_creation_budget_ms(pos_integer() | nil, pos_integer() | nil) :: non_neg_integer()
  def room_creation_budget_ms(user_id, integration_id)
      when is_integer(user_id) and is_integer(integration_id) do
    with {:ok, integration} <- Video.fetch_integration_for_user(integration_id, user_id),
         {:ok, provider_type} when provider_type != :none <-
           ProviderConfig.parse_known(integration.provider) do
      ProviderConfig.room_creation_budget_ms(provider_type)
    else
      _unresolved -> ProviderConfig.room_creation_budget_ms()
    end
  end

  def room_creation_budget_ms(_user_id, _integration_id),
    do: ProviderConfig.room_creation_budget_ms()

  @doc """
  Rebuilds the context of a room that already exists, so its join URLs can be
  built again without asking the provider for a new room.

  The room keeps its stored identity (`:room_id`, `:meeting_url`); only the
  provider config is resolved afresh from the integration, which is what
  carries the credentials a join URL may be signed with.

  ## Required opts
    - `:integration_id` - the video integration that owns the room
    - `:room_id` - provider-specific room identifier

  ## Optional opts
    - `:meeting_url` - the room's stored URL
    - `:meeting_id` - the meeting the room belongs to
  """
  @spec existing_room_context(pos_integer() | nil, keyword()) ::
          {:ok, MeetingContext.t()} | {:error, any()}
  def existing_room_context(user_id, opts) do
    with {:ok, room_id} <- fetch_required_opt(opts, :room_id),
         {:ok, provider_type, config} <- get_provider_config(user_id, opts),
         {:ok, provider_module} <- ProviderConfig.get_provider(provider_type) do
      {:ok,
       %MeetingContext{
         provider_type: provider_type,
         provider_module: provider_module,
         room_data: %RoomData{
           room_id: room_id,
           meeting_url: Keyword.get(opts, :meeting_url),
           provider_data: %{},
           provider_config: config
         }
       }}
    end
  end

  @doc """
  A room's join URL for a recipient it has no name for: a booking's guests,
  and the link written into a calendar event's description. See
  `ProviderAdapter.shared_join_url/2`.
  """
  @spec shared_join_url(MeetingContext.t(), DateTime.t() | nil) ::
          {:ok, String.t() | nil} | {:error, term()}
  defdelegate shared_join_url(meeting_context, meeting_time), to: ProviderAdapter

  @doc """
  Whether a room's join URLs stop working some time after the meeting time
  they were built for. See `ProviderAdapter.time_bound_join_urls?/1`.
  """
  @spec time_bound_join_urls?(MeetingContext.t()) :: boolean()
  defdelegate time_bound_join_urls?(meeting_context), to: ProviderAdapter

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
    with {:ok, room_id} <- fetch_required_opt(opts, :room_id),
         {:ok, provider_type, config} <- get_provider_config(user_id, opts) do
      ProviderAdapter.update_meeting_room(
        provider_type,
        room_id,
        merge_meeting_attrs(config, opts)
      )
    end
  end

  @doc """
  Deletes a meeting room on the provider's side (e.g. on cancellation).

  Looks up the provider for `integration_id`, dispatches to the provider's
  `delete_meeting_room/2` callback. Providers without a server-side meeting
  object silently succeed, and so does a room the provider no longer has
  (`ProviderAdapter.delete_meeting_room/3`), so cancellation is idempotent.

  ## Required opts
    - `:integration_id` — the video integration that owns the room
    - `:room_id` — provider-specific room identifier
  """
  @spec delete_meeting_room(pos_integer() | nil, keyword()) :: :ok | {:error, any()}
  def delete_meeting_room(user_id, opts) do
    with {:ok, room_id} <- fetch_required_opt(opts, :room_id),
         {:ok, provider_type, config} <- get_provider_config(user_id, opts) do
      ProviderAdapter.delete_meeting_room(provider_type, room_id, config)
    end
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
  @spec create_join_url(MeetingContext.t(), String.t(), String.t(), String.t(), DateTime.t()) ::
          {:ok, String.t()} | {:error, any()}
  def create_join_url(meeting_context, participant_name, participant_email, role, meeting_time) do
    ProviderAdapter.create_join_url(
      meeting_context,
      participant_name,
      participant_email,
      role,
      meeting_time
    )
  end

  # Private helpers
  defp get_provider_config(user_id, opts) do
    with {:ok, _integration, provider_type, config} <- resolve_integration(user_id, opts) do
      {:ok, provider_type, config}
    end
  end

  defp resolve_integration(user_id, opts) do
    case get_integration_from_database(user_id, opts) do
      {:ok, integration} ->
        {provider_type, config} = build_provider_config(integration, opts)
        {:ok, integration, provider_type, config}

      :not_found ->
        {:error,
         "No video integration configured. Please add a video integration in the dashboard."}

      {:error, :user_id_required} ->
        {:error, :user_id_required}
    end
  end

  defp build_provider_config(integration, opts) do
    case ProviderConfig.parse_known(integration.provider) do
      {:ok, :none} ->
        {:none, %{}}

      {:ok, provider_type} ->
        build_via_module(provider_type, integration, opts)

      {:error, :unknown} ->
        {:unknown, %{}}
    end
  end

  defp build_via_module(provider_type, integration, opts) do
    case ProviderConfig.get_provider_module(provider_type) do
      nil ->
        {provider_type, %{}}

      module ->
        decrypted = VideoIntegrationSchema.decrypt_credentials(integration)
        {provider_type, invoke_build_config(module, integration, decrypted, opts)}
    end
  end

  @spec invoke_build_config(module(), term(), term(), keyword()) :: map()
  defp invoke_build_config(module, integration, decrypted, opts) do
    module.build_config(integration, decrypted, opts)
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
