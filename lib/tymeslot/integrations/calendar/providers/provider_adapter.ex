defmodule Tymeslot.Integrations.Calendar.Providers.ProviderAdapter do
  @moduledoc """
  Adapter that wraps calendar provider calls with common functionality.

  This module provides a unified interface for all calendar providers,
  handling common concerns like error handling, logging, and metrics.
  """

  require Logger
  alias Tymeslot.Infrastructure.Metrics
  alias Tymeslot.Integrations.Calendar.Providers.ProviderRegistry

  @doc """
  Creates a new client using the specified provider.

  ## Options
  - `skip_validation`: Skip config validation for operational client creation (default: false)
  """
  @spec new_client(atom(), map() | term(), keyword()) :: map() | {:error, term()}
  def new_client(provider_type, config, opts \\ []) do
    case ProviderRegistry.create_client(provider_type, config, opts) do
      {:ok, client} ->
        %{
          provider_type: provider_type,
          client: client,
          provider_module: ProviderRegistry.get_provider!(provider_type)
        }

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Lists all events from the calendar.
  """
  @spec get_events(map()) :: {:ok, list()} | {:error, term()}
  def get_events(adapter_client) do
    Metrics.time_operation(:calendar_get_events, %{provider: adapter_client.provider_type}, fn ->
      Logger.debug("Getting events from #{adapter_client.provider_type} calendar")

      case adapter_client.provider_module.get_events(adapter_client.client) do
        {:ok, events} = result ->
          Logger.debug("Successfully retrieved #{length(events)} events")
          result

        {:error, reason} = error ->
          Logger.error("Failed to get events from #{adapter_client.provider_type}",
            reason: inspect(reason)
          )

          error
      end
    end)
  end

  @doc """
  Lists events within a specific date range.
  """
  @spec get_events(map(), DateTime.t(), DateTime.t()) :: {:ok, list()} | {:error, term()}
  def get_events(adapter_client, start_time, end_time) do
    Metrics.time_operation(
      :calendar_get_events_range,
      %{provider: adapter_client.provider_type},
      fn ->
        Logger.debug("Getting events from #{adapter_client.provider_type} calendar",
          start_time: start_time,
          end_time: end_time
        )

        case adapter_client.provider_module.get_events(
               adapter_client.client,
               start_time,
               end_time
             ) do
          {:ok, events} = result ->
            Logger.debug("Successfully retrieved #{length(events)} events in range")
            result

          {:error, reason} = error ->
            Logger.error("Failed to get events in range from #{adapter_client.provider_type}",
              reason: inspect(reason)
            )

            error
        end
      end
    )
  end

  @doc """
  Creates a new event in the calendar.
  """
  @spec create_event(map(), map()) :: {:ok, term()} | {:error, term()}
  def create_event(adapter_client, event_data) do
    Metrics.time_operation(
      :calendar_create_event,
      %{provider: adapter_client.provider_type},
      fn ->
        Logger.info("Creating event in #{adapter_client.provider_type} calendar")

        case adapter_client.provider_module.create_event(adapter_client.client, event_data) do
          {:ok, _} = result ->
            Logger.info("Successfully created event")
            result

          {:error, reason} = error ->
            Logger.error("Failed to create event in #{adapter_client.provider_type}",
              reason: inspect(reason)
            )

            error
        end
      end
    )
  end

  @doc """
  Updates an existing event in the calendar.
  """
  @spec update_event(map(), String.t(), map()) :: :ok | {:error, term()}
  def update_event(adapter_client, uid, event_data) do
    Metrics.time_operation(
      :calendar_update_event,
      %{provider: adapter_client.provider_type},
      fn ->
        Logger.info("Updating event in #{adapter_client.provider_type} calendar", uid: uid)

        case adapter_client.provider_module.update_event(adapter_client.client, uid, event_data) do
          :ok ->
            Logger.info("Successfully updated event", uid: uid)
            :ok

          {:ok, _updated} ->
            # Be tolerant of providers that return {:ok, event}
            Logger.info("Successfully updated event", uid: uid)
            :ok

          {:error, reason} = error ->
            Logger.error("Failed to update event in #{adapter_client.provider_type}",
              uid: uid,
              reason: inspect(reason)
            )

            error
        end
      end
    )
  end

  @doc """
  Deletes an event from the calendar.
  """
  @spec delete_event(map(), String.t()) :: :ok | {:error, term()}
  def delete_event(adapter_client, uid) do
    Metrics.time_operation(
      :calendar_delete_event,
      %{provider: adapter_client.provider_type},
      fn ->
        Logger.info("Deleting event from #{adapter_client.provider_type} calendar", uid: uid)

        case adapter_client.provider_module.delete_event(adapter_client.client, uid) do
          :ok ->
            Logger.info("Successfully deleted event", uid: uid)
            :ok

          {:ok, _deleted} ->
            # Be tolerant of providers that return {:ok, payload}
            Logger.info("Successfully deleted event", uid: uid)
            :ok

          {:error, reason} = error ->
            Logger.error("Failed to delete event from #{adapter_client.provider_type}",
              uid: uid,
              reason: inspect(reason)
            )

            error
        end
      end
    )
  end
end
