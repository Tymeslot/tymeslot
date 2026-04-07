defmodule Tymeslot.Integrations.Calendar.Runtime.ClientManager do
  @moduledoc """
  Manages calendar client creation and booking integration resolution.

  Responsibilities:
  - Create provider-specific clients (OAuth, CalDAV, Debug)
  - Resolve booking calendar based on Meeting, MeetingType, or user_id context
  - Look up integrations and map them to configured clients
  """

  require Logger
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Providers.ProviderAdapter
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Utils.UriUtils

  @type user_id :: pos_integer()
  @type integration_id :: pos_integer()
  @type client :: map()

  @doc """
  Gets configured calendar clients for all calendars.
  Returns a list of adapter clients, one for each configured calendar path.
  """
  @spec clients(user_id() | nil) :: [client()]
  def clients(user_id \\ nil) do
    case get_integrations_from_database(user_id) do
      {:ok, integrations} ->
        Enum.flat_map(integrations, &create_clients_from_integration/1)

      :not_found ->
        Logger.warning(
          "No calendar integrations configured. Please add calendar integrations in the dashboard."
        )

        []

      {:error, :user_id_required} ->
        Logger.warning(
          "User ID is required for calendar operations. Please ensure user context is available."
        )

        []
    end
  end

  @doc """
  Gets a single configured calendar client (for backward compatibility).
  Uses the first configured calendar path.
  """
  @spec client(user_id() | nil) :: client() | nil
  def client(user_id \\ nil) do
    List.first(clients(user_id))
  end

  @doc """
  Gets the calendar client for creating bookings.
  Can take a user_id (fallback to primary), a Meeting, or a MeetingType to resolve the destination.
  """
  @spec booking_client(user_id() | MeetingSchema.t() | MeetingTypeSchema.t() | nil) ::
          client() | nil
  def booking_client(context \\ nil) do
    context
    |> resolve_booking_integration()
    |> create_client_from_integration()
  end

  @doc """
  Gets the booking calendar integration info for a user or meeting type.
  Returns the integration ID and calendar path that will be used for creating bookings.
  """
  @spec get_booking_integration_info(user_id() | MeetingSchema.t() | MeetingTypeSchema.t()) ::
          {:ok, %{integration_id: integration_id(), calendar_path: String.t()}}
          | {:error, atom()}
  def get_booking_integration_info(%MeetingSchema{} = meeting) do
    if is_integer(meeting.calendar_integration_id) and is_binary(meeting.calendar_path) do
      case CalendarIntegrationQueries.get_for_user(
             meeting.calendar_integration_id,
             meeting.organizer_user_id
           ) do
        {:ok, integration} when integration.is_active ->
          {:ok,
           %{
             integration_id: meeting.calendar_integration_id,
             calendar_path: meeting.calendar_path
           }}

        _not_found_or_inactive ->
          get_booking_integration_info(meeting.organizer_user_id)
      end
    else
      get_booking_integration_info(meeting.organizer_user_id)
    end
  end

  def get_booking_integration_info(%MeetingTypeSchema{} = mt) do
    if is_integer(mt.calendar_integration_id) and is_binary(mt.target_calendar_id) do
      case CalendarIntegrationQueries.get_for_user(mt.calendar_integration_id, mt.user_id) do
        {:ok, integration} when integration.is_active ->
          {:ok,
           %{
             integration_id: mt.calendar_integration_id,
             calendar_path: mt.target_calendar_id
           }}

        _not_found_or_inactive ->
          get_booking_integration_info(mt.user_id)
      end
    else
      get_booking_integration_info(mt.user_id)
    end
  end

  def get_booking_integration_info(user_id) when is_integer(user_id) do
    case resolve_booking_integration(user_id) do
      nil ->
        {:error, :no_integration}

      integration ->
        {:ok,
         %{
           integration_id: integration.id,
           calendar_path: resolve_calendar_path(integration)
         }}
    end
  end

  @doc """
  Gets a client by integration ID, with optional user_id validation.
  """
  @spec get_client_by_integration_id(integration_id(), user_id()) :: client() | nil
  def get_client_by_integration_id(integration_id, user_id) do
    case CalendarIntegrationQueries.get_for_user(integration_id, user_id) do
      {:error, :not_found} ->
        nil

      {:ok, integration} ->
        provider_type =
          try do
            String.to_existing_atom(integration.provider)
          rescue
            ArgumentError -> :unknown
          end

        case provider_type do
          provider when provider in [:google, :outlook] ->
            create_adapter_client(provider_type, integration)

          provider when provider in [:caldav, :nextcloud, :radicale, :zimbra] ->
            create_caldav_client(provider_type, integration)

          _not_found_or_inactive ->
            Logger.error("Unknown calendar provider", provider: provider_type)
            nil
        end
    end
  end

  @doc """
  Resolves a calendar client from various context types.
  Supports:
  - %MeetingSchema{} (uses stored integration_id and user_id)
  - {integration_id, user_id} tuple
  - user_id (integer)
  - nil (returns default client for current context if possible)
  """
  @spec resolve_client(user_id() | MeetingSchema.t() | {integration_id(), user_id()} | nil) ::
          client() | nil
  def resolve_client(context) do
    case context do
      %MeetingSchema{calendar_integration_id: integration_id, organizer_user_id: user_id}
      when is_integer(integration_id) ->
        get_client_by_integration_id(integration_id, user_id)

      %MeetingSchema{organizer_user_id: user_id} when is_integer(user_id) ->
        client(user_id)

      {integration_id, user_id} when is_integer(integration_id) and is_integer(user_id) ->
        get_client_by_integration_id(integration_id, user_id)

      user_id when is_integer(user_id) ->
        client(user_id)

      _not_found_or_inactive ->
        client()
    end
  end

  # --- Private Implementation ---

  defp create_clients_from_integration(integration) do
    provider_type =
      try do
        String.to_existing_atom(integration.provider)
      rescue
        ArgumentError -> :unknown
      end

    case provider_type do
      # OAuth-based providers use the integration directly
      provider when provider in [:google, :outlook] ->
        create_oauth_client(provider_type, integration)

      # CalDAV providers use config map with calendar paths
      provider when provider in [:caldav, :radicale, :nextcloud, :zimbra] ->
        create_caldav_clients(provider_type, integration)

      # Debug provider for development testing
      :debug ->
        create_debug_client(integration)

      _unknown_provider ->
        Logger.warning("Unknown provider type", provider_type: inspect(provider_type))
        []
    end
  end

  defp create_oauth_client(provider_type, integration) do
    # Skip validation for operational client creation to avoid rate limiting
    case ProviderAdapter.new_client(provider_type, integration, skip_validation: true) do
      %{client: _client, provider_module: _module, provider_type: _type} = adapter_client ->
        [adapter_client]

      {:error, reason} ->
        Logger.error("Failed to create calendar client",
          provider_type: provider_type,
          reason: reason
        )

        []
    end
  end

  defp create_caldav_clients(provider_type, integration) do
    # If calendar_list is populated, use it to filter selected calendars
    paths =
      if integration.calendar_list && integration.calendar_list != [] do
        integration.calendar_list
        |> Enum.filter(fn cal ->
          cal["selected"] == true || cal[:selected] == true
        end)
        |> Enum.map(fn cal ->
          cal["path"] || cal[:path] || cal["id"] || cal[:id]
        end)
        |> Enum.reject(&is_nil/1)
      else
        # Fallback to calendar_paths for backward compatibility
        integration.calendar_paths || []
      end

    paths
    |> Enum.map(fn path ->
      config = %{
        base_url: integration.base_url,
        username: integration.username,
        password: integration.password,
        calendar_path: path,
        calendar_paths: [path],
        verify_ssl: true
      }

      # Skip validation for operational client creation to avoid rate limiting
      case ProviderAdapter.new_client(provider_type, config, skip_validation: true) do
        %{client: _client, provider_module: _module, provider_type: _type} = adapter_client ->
          adapter_client

        {:error, reason} ->
          Logger.error("Failed to create calendar client",
            provider_type: provider_type,
            path: path,
            reason: reason
          )

          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp create_debug_client(integration) do
    # Debug provider for development testing
    if Application.get_env(:tymeslot, :environment) in [:dev, :test] do
      # Skip validation for debug client
      case ProviderAdapter.new_client(:debug, %{user_id: integration.user_id},
             skip_validation: true
           ) do
        %{client: _client, provider_module: _module, provider_type: _type} = adapter_client ->
          [adapter_client]

        {:error, reason} ->
          Logger.error("Failed to create debug client", reason: reason)
          []
      end
    else
      Logger.warning("Debug calendar provider is only available in development/test environments")
      []
    end
  end

  # Private helper to resolve the appropriate booking integration based on context
  defp resolve_booking_integration(nil), do: nil

  defp resolve_booking_integration({integration_id, user_id})
       when is_integer(integration_id) and is_integer(user_id) do
    case CalendarIntegrationQueries.get_for_user(integration_id, user_id) do
      {:ok, integration} when integration.is_active -> integration
      _not_found_or_inactive -> resolve_booking_integration(user_id)
    end
  end

  defp resolve_booking_integration(%MeetingSchema{} = meeting) do
    cond do
      is_integer(meeting.calendar_integration_id) ->
        case CalendarIntegrationQueries.get_for_user(
               meeting.calendar_integration_id,
               meeting.organizer_user_id
             ) do
          {:ok, integration} when integration.is_active ->
            # Override default_booking_calendar_id with the one stored in the meeting
            %{integration | default_booking_calendar_id: meeting.calendar_path}

          _not_found_or_inactive ->
            resolve_booking_integration(meeting.organizer_user_id)
        end

      is_integer(meeting.organizer_user_id) ->
        resolve_booking_integration(meeting.organizer_user_id)

      true ->
        nil
    end
  end

  defp resolve_booking_integration(%MeetingTypeSchema{} = meeting_type) do
    cond do
      is_integer(meeting_type.calendar_integration_id) ->
        case CalendarIntegrationQueries.get_for_user(
               meeting_type.calendar_integration_id,
               meeting_type.user_id
             ) do
          {:ok, integration} when integration.is_active ->
            # Override default_booking_calendar_id with the one stored in the meeting type
            %{integration | default_booking_calendar_id: meeting_type.target_calendar_id}

          _not_found_or_inactive ->
            resolve_booking_integration(meeting_type.user_id)
        end

      is_integer(meeting_type.user_id) ->
        resolve_booking_integration(meeting_type.user_id)

      true ->
        nil
    end
  end

  defp resolve_booking_integration(user_id) when is_integer(user_id) do
    case CalendarPrimary.get_primary_calendar_integration(user_id) do
      {:ok, integration} when is_binary(integration.default_booking_calendar_id) ->
        integration

      {:ok, integration} ->
        # Primary exists but no booking calendar set, try to find any with booking calendar
        # if none found, return the primary integration itself as ultimate fallback
        find_integration_with_booking_calendar(user_id) || integration

      {:error, _reason} ->
        # No primary set, find any with booking calendar
        # if still none found, just pick the first integration
        find_integration_with_booking_calendar(user_id) || pick_first_integration(user_id)
    end
  end

  defp resolve_booking_integration(_not_found_or_inactive), do: nil

  defp pick_first_integration(user_id) do
    case get_integrations_from_database(user_id) do
      {:ok, integrations} -> List.first(integrations)
      _not_found_or_inactive -> nil
    end
  end

  defp find_integration_with_booking_calendar(user_id) do
    case get_integrations_from_database(user_id) do
      {:ok, integrations} ->
        Enum.find(integrations, & &1.default_booking_calendar_id)

      _not_found_or_inactive ->
        nil
    end
  end

  defp create_client_from_integration(nil), do: nil

  defp create_client_from_integration(integration) do
    create_booking_client_from_integration(integration)
  end

  defp create_booking_client_from_integration(integration) do
    provider_type =
      try do
        String.to_existing_atom(integration.provider)
      rescue
        ArgumentError -> :unknown
      end

    case provider_type do
      provider when provider in [:google, :outlook] ->
        create_adapter_client(provider_type, integration)

      provider when provider in [:caldav, :nextcloud, :radicale, :zimbra] ->
        create_caldav_client(provider_type, integration)

      _not_found_or_inactive ->
        nil
    end
  end

  defp create_caldav_client(provider_type, integration) do
    calendar_path = resolve_calendar_path(integration)

    if calendar_path do
      config = %{
        base_url: integration.base_url,
        username: integration.username,
        password: integration.password,
        calendar_path: calendar_path,
        calendar_paths: [calendar_path],
        verify_ssl: true
      }

      create_adapter_client(provider_type, config)
    else
      nil
    end
  end

  defp resolve_calendar_path(integration) do
    calendar_id = integration.default_booking_calendar_id

    if calendar_id && integration.calendar_list do
      find_calendar_path_by_id(integration.calendar_list, calendar_id)
    else
      List.first(integration.calendar_paths || [])
    end
  end

  defp find_calendar_path_by_id(calendar_list, calendar_id) do
    calendar = Enum.find(calendar_list, &calendar_matches_id?(&1, calendar_id))

    if calendar do
      calendar["path"] || calendar[:path] || calendar_id
    else
      calendar_id
    end
  end

  defp calendar_matches_id?(calendar, calendar_id) do
    UriUtils.uri_safe_match?(calendar["id"] || calendar[:id], calendar_id)
  end

  defp create_adapter_client(provider_type, config) do
    # Skip validation for operational client creation to avoid rate limiting during normal operations
    case ProviderAdapter.new_client(provider_type, config, skip_validation: true) do
      %{client: _client, provider_module: _module, provider_type: _type} = adapter_client ->
        adapter_client

      {:error, reason} ->
        Logger.error("Failed to create calendar client",
          provider_type: provider_type,
          reason: reason
        )

        nil
    end
  end

  defp get_integrations_from_database(user_id) do
    case user_id do
      nil ->
        # User ID is required for calendar integrations
        {:error, :user_id_required}

      user_id ->
        # Use the specific user's calendar integrations
        case CalendarManagement.list_active_calendar_integrations(user_id) do
          integrations when integrations != [] -> {:ok, integrations}
          _not_found_or_inactive -> :not_found
        end
    end
  end
end
