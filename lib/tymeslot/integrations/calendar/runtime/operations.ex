defmodule Tymeslot.Integrations.Calendar.Operations do
  @moduledoc """
  Core calendar operations using various calendar providers.
  This module is invoked by the main context (Tymeslot.Integrations.Calendar).
  """

  @behaviour Tymeslot.Integrations.Calendar.CalendarBehaviour
  require Logger
  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.Infrastructure.Metrics
  alias Tymeslot.Integrations.Calendar.CalDAV.Base
  alias Tymeslot.Integrations.Calendar.EventsRead
  alias Tymeslot.Integrations.Calendar.Providers.ProviderAdapter
  alias Tymeslot.Integrations.Calendar.RequestCoalescer
  alias Tymeslot.Integrations.Calendar.Utils.EventValidator
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.CalendarPrimary

  @doc """
  Gets configured calendar clients for all calendars.
  Returns a list of adapter clients, one for each configured calendar path.
  """
  @spec clients(integer() | nil) :: list(map())
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
      provider when provider in [:caldav, :radicale, :nextcloud] ->
        create_caldav_clients(provider_type, integration)

      # Debug provider for development testing
      :debug ->
        create_debug_client(integration)

      _ ->
        Logger.warning("Unknown provider type: #{inspect(provider_type)}")
        []
    end
  end

  defp create_oauth_client(provider_type, integration) do
    # Skip validation for operational client creation to avoid rate limiting
    case ProviderAdapter.new_client(provider_type, integration, skip_validation: true) do
      %{client: _, provider_module: _, provider_type: _} = adapter_client ->
        [adapter_client]

      {:error, reason} ->
        Logger.error("Failed to create #{provider_type} client", reason: reason)
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
        %{client: _, provider_module: _, provider_type: _} = adapter_client ->
          adapter_client

        {:error, reason} ->
          Logger.error("Failed to create #{provider_type} client for path #{path}",
            reason: reason
          )

          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp create_debug_client(integration) do
    # Debug provider for development testing
    if Mix.env() in [:dev, :test] do
      # Skip validation for debug client
      case ProviderAdapter.new_client(:debug, %{user_id: integration.user_id},
             skip_validation: true
           ) do
        %{client: _, provider_module: _, provider_type: _} = adapter_client ->
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

  @doc """
  Gets a single configured calendar client (for backward compatibility).
  Uses the first configured calendar path.
  """
  @spec client(integer() | nil) :: map() | nil
  def client(user_id \\ nil) do
    List.first(clients(user_id))
  end

  @doc """
  Gets the calendar client for creating bookings.
  Uses the user's primary calendar integration with booking calendar set.
  """
  @spec booking_client(integer() | nil) :: map() | nil
  def booking_client(user_id \\ nil) do
    user_id
    |> get_booking_integration()
    |> create_client_from_integration()
  end

  # Private helper to get the appropriate booking integration
  defp get_booking_integration(nil) do
    Logger.warning("User ID is required for booking calendar operations")
    nil
  end

  defp get_booking_integration(user_id) do
    case CalendarPrimary.get_primary_calendar_integration(user_id) do
      {:ok, integration} when not is_nil(integration.default_booking_calendar_id) ->
        integration

      {:ok, _integration} ->
        # Primary exists but no booking calendar set, find any with booking calendar
        find_integration_with_booking_calendar(user_id)

      {:error, :no_primary_set} ->
        # No primary set, find any with booking calendar
        find_integration_with_booking_calendar(user_id)

      {:error, :not_found} ->
        # User profile not found
        nil
    end
  end

  defp find_integration_with_booking_calendar(user_id) do
    case get_integrations_from_database(user_id) do
      {:ok, integrations} ->
        Enum.find(integrations, & &1.default_booking_calendar_id)

      _ ->
        nil
    end
  end

  defp create_client_from_integration(nil), do: nil

  defp create_client_from_integration(integration) do
    create_booking_client_from_integration(integration)
  end

  @doc """
  Gets the booking calendar integration info for a user.
  Returns the integration ID and calendar path that will be used for creating bookings.
  """
  @spec get_booking_integration_info(integer()) :: {:ok, map()} | {:error, atom()}
  def get_booking_integration_info(user_id) do
    with {:ok, integrations} <- get_integrations_from_database(user_id),
         integration <-
           Enum.find(integrations, & &1.default_booking_calendar_id) ||
             List.first(integrations),
         true <- not is_nil(integration) do
      {:ok,
       %{
         integration_id: integration.id,
         calendar_path:
           integration.default_booking_calendar_id ||
             List.first(integration.calendar_paths)
       }}
    else
      :not_found ->
        {:error, :no_integration}

      {:error, :user_id_required} ->
        {:error, :user_id_required}

      false ->
        {:error, :no_integration}
    end
  end

  defp get_client_by_integration_id(integration_id) do
    case CalendarIntegrationQueries.get(integration_id) do
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

          provider when provider in [:caldav, :nextcloud, :radicale] ->
            create_caldav_client(provider_type, integration)

          _ ->
            Logger.error("Unknown calendar provider", provider: provider_type)
            nil
        end
    end
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

      provider when provider in [:caldav, :nextcloud, :radicale] ->
        create_caldav_client(provider_type, integration)

      _ ->
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
    (calendar["id"] || calendar[:id]) == calendar_id
  end

  @doc """
  Lists all events from all configured calendars.
  Fetches from all calendars in parallel for better performance.
  """
  @spec list_events(integer() | nil) :: {:ok, list(map())} | {:error, term()}
  def list_events(user_id \\ nil) do
    Metrics.time_operation(:list_events, %{calendar_count: length(clients(user_id))}, fn ->
      Logger.info("Listing all calendar events from all calendars")

      all_clients = clients(user_id)
      Logger.info("Fetching from #{length(all_clients)} calendar(s) in parallel")

      results =
        all_clients
        |> Task.async_stream(&fetch_events_from_client/1, timeout: 30_000)
        |> unwrap_async_results()

      successful_results = Enum.filter(results, &successful_result?/1)

      if Enum.empty?(successful_results) do
        {:error, "Failed to fetch from any calendar"}
      else
        all_events =
          successful_results
          |> Enum.flat_map(&extract_events/1)
          |> Enum.uniq_by(& &1.uid)

        Logger.info("Total events found across all calendars: #{length(all_events)}")
        {:ok, all_events}
      end
    end)
  end

  @doc """
  Creates a new event.
  """
  @spec create_event(map(), integer() | nil) :: {:ok, map()} | {:error, term()}
  def create_event(event_data, user_id \\ nil) do
    Metrics.time_operation(:create_event, %{}, fn ->
      Logger.info("Creating new calendar event")

      with :ok <- validate_event(event_data),
           client when not is_nil(client) <- booking_client(user_id),
           {:ok, _event} = result <- ProviderAdapter.create_event(client, event_data) do
        Logger.info("Successfully created calendar event")
        result
      else
        nil ->
          Logger.error(
            "Failed to create calendar event - no calendar client available",
            user_id: user_id
          )

          {:error, :no_calendar_client}

        {:error, :invalid_event_data} = error ->
          error

        {:error, reason} = error ->
          Logger.error("Failed to create calendar event", reason: inspect(reason))
          error
      end
    end)
  end

  @doc """
  Updates an existing event.
  Now accepts optional calendar_integration_id to use specific calendar.
  """
  @spec update_event(String.t(), map(), integer() | nil) ::
          {:ok, :updated} | {:error, atom()}
  def update_event(uid, event_data, calendar_integration_id \\ nil) do
    Metrics.time_operation(:update_event, %{uid: uid}, fn ->
      Logger.info("Updating calendar event", uid: uid)

      calendar_client =
        if calendar_integration_id do
          get_client_by_integration_id(calendar_integration_id)
        else
          client()
        end

      with client when not is_nil(client) <- calendar_client,
           :ok <- ProviderAdapter.update_event(client, uid, event_data) do
        Logger.info("Successfully updated calendar event", uid: uid)
        {:ok, :updated}
      else
        nil ->
          Logger.error("No calendar integration found", integration_id: calendar_integration_id)
          {:error, :no_calendar_integration}

        {:error, reason} = error ->
          Logger.error("Failed to update calendar event", uid: uid, reason: inspect(reason))
          error
      end
    end)
  end

  @doc """
  Deletes an event.
  Now accepts optional calendar_integration_id to use specific calendar.
  """
  @spec delete_event(String.t(), integer() | nil) :: {:ok, :deleted} | {:error, term()}
  def delete_event(uid, calendar_integration_id \\ nil) do
    Metrics.time_operation(:delete_event, %{uid: uid}, fn ->
      Logger.info("Deleting calendar event", uid: uid)

      calendar_client =
        if calendar_integration_id do
          get_client_by_integration_id(calendar_integration_id)
        else
          client()
        end

      with client when not is_nil(client) <- calendar_client,
           :ok <- ProviderAdapter.delete_event(client, uid) do
        Logger.info("Successfully deleted calendar event", uid: uid)
        {:ok, :deleted}
      else
        nil ->
          Logger.warning(
            "No calendar integration available to delete event",
            uid: uid,
            integration_id: calendar_integration_id
          )

          # Return success since we can't delete from a non-existent calendar
          # and the meeting is being cancelled anyway
          {:ok, :deleted}

        {:error, reason} = error ->
          Logger.error(
            "Failed to delete calendar event",
            uid: uid,
            reason: inspect(reason)
          )

          error
      end
    end)
  end

  defp validate_event(event_data) do
    case EventValidator.validate(event_data) do
      {:ok, _} -> :ok
      {:error, _cs} -> {:error, :invalid_event_data}
    end
  end

  defp unwrap_async_results(stream) do
    Enum.map(stream, fn
      {:ok, res} -> res
      {:exit, _} -> {:error, :task_exit}
      other -> other
    end)
  end

  defp successful_result?({:ok, _events, _path}), do: true
  defp successful_result?(_), do: false

  defp extract_events({:ok, events, _path}), do: events

  @spec get_event(String.t()) :: {:ok, map()} | {:error, term()}
  def get_event(uid) do
    Logger.debug("Getting calendar event", uid: uid)

    case list_events() do
      {:ok, events} ->
        event = Enum.find(events, &(&1.uid == uid))

        if event do
          Logger.debug("Found calendar event", uid: uid)
          {:ok, event}
        else
          Logger.warning("Calendar event not found", uid: uid)
          {:error, :not_found}
        end

      error ->
        error
    end
  end

  @doc """
  Gets events for a month for display purposes.
  Uses request coalescing to prevent duplicate API calls.
  """
  @spec get_events_for_month(integer(), integer(), integer(), String.t()) ::
          {:ok, list(map())} | {:error, term()}
  def get_events_for_month(user_id, year, month, timezone) do
    Metrics.time_operation(:get_events_for_month, %{year: year, month: month}, fn ->
      Logger.info("Getting events for month", year: year, month: month, timezone: timezone)

      # Calculate date range for the month
      start_date = Date.new!(year, month, 1)
      end_date = Date.end_of_month(start_date)

      get_events_for_range_fresh(user_id, start_date, end_date)
    end)
  end

  @doc """
  Gets fresh events for a date range.
  Uses request coalescing to prevent duplicate API calls when multiple
  requests for the same date range occur simultaneously.
  """
  @spec get_events_for_range_fresh(Date.t(), Date.t()) :: {:error, term()}
  def get_events_for_range_fresh(_start_date, _end_date) do
    # No implicit user context allowed anymore
    {:error, :user_id_required}
  end

  @spec get_events_for_range_fresh(integer(), Date.t(), Date.t()) ::
          {:ok, list(map())} | {:error, term()}
  def get_events_for_range_fresh(user_id, start_date, end_date) when is_integer(user_id) do
    RequestCoalescer.coalesce(user_id, start_date, end_date, fn ->
      fetch_events_from_providers(user_id, start_date, end_date)
    end)
  end

  # Private function that does the actual fetching
  defp fetch_events_from_providers(user_id, start_date, end_date) do
    Logger.info("Fetching fresh events for range", start_date: start_date, end_date: end_date)

    # Convert dates to DateTime for provider adapters
    start_datetime = DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC")
    end_datetime = DateTime.new!(end_date, ~T[23:59:59], "Etc/UTC")

    # Fetch events from all configured calendars
    all_clients = clients(user_id)

    # Fetch events from each calendar in parallel
    tasks =
      Enum.map(all_clients, fn client ->
        Task.async(fn ->
          fetch_events_for_client_in_range(client, start_datetime, end_datetime)
        end)
      end)

    # Wait for all tasks to complete
    results = Task.await_many(tasks, Base.task_await_timeout_ms())

    # Combine all successful results
    all_events =
      results
      |> Enum.filter(&match?({:ok, _events, _path}, &1))
      |> Enum.flat_map(fn {:ok, events, _path} -> events end)
      |> Enum.uniq_by(& &1.uid)

    Logger.info("Total fresh events found across all calendars: #{length(all_events)}")
    {:ok, all_events}
  end

  defp fetch_events_for_client_in_range(client, start_datetime, end_datetime) do
    EventsRead.fetch_events_with_fallback(client, start_datetime, end_datetime)
  end

  @doc """
  Lists events within a date range from all configured calendars.
  Uses server-side filtering to exclude events outside the range.
  Fetches from all calendars in parallel for better performance.

  DEPRECATED: Use get_events_for_range_fresh/2 instead.
  """
  @spec list_events_in_range(DateTime.t() | Date.t(), DateTime.t() | Date.t()) ::
          {:ok, list(map())} | {:error, term()}
  def list_events_in_range(start_date_or_dt, end_date_or_dt) do
    EventsRead.list_events_in_range(start_date_or_dt, end_date_or_dt)
  end

  # Fallback utilities moved to EventsRead; keep thin wrappers if still referenced

  defp fetch_events_from_client(client) do
    EventsRead.fetch_events_without_range(client)
  end

  defp create_adapter_client(provider_type, config) do
    # Skip validation for operational client creation to avoid rate limiting during normal operations
    case ProviderAdapter.new_client(provider_type, config, skip_validation: true) do
      %{client: _, provider_module: _, provider_type: _} = adapter_client ->
        adapter_client

      {:error, reason} ->
        Logger.error("Failed to create #{provider_type} client", reason: reason)
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
          _ -> :not_found
        end
    end
  end
end
