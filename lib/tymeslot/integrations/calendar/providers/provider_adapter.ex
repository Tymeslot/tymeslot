defmodule Tymeslot.Integrations.Calendar.Providers.ProviderAdapter do
  @moduledoc """
  Adapter that wraps calendar provider calls with common functionality.

  This module provides a unified interface for all calendar providers,
  handling common concerns like error handling, logging, and metrics.
  """

  require Logger
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Infrastructure.Metrics
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Providers.ProviderRegistry
  alias Tymeslot.Integrations.Calendar.Shared.FetchAggregate.Outcome

  @type adapter_client :: %{
          required(:provider_type) => atom(),
          required(:client) => term(),
          required(:provider_module) => module()
        }

  @doc """
  Creates a new client using the specified provider.

  ## Options
  - `skip_validation`: Skip config validation for operational client creation (default: false)
  """
  @spec new_client(atom(), map() | term(), keyword()) :: adapter_client() | {:error, term()}
  def new_client(provider_type, config, opts \\ []) do
    case ProviderRegistry.create_client(provider_type, config, opts) do
      {:ok, client} ->
        %{
          provider_type: provider_type,
          client: client,
          provider_module: ProviderRegistry.get_provider!(provider_type)
        }

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Creates a new adapter client from a persisted `CalendarIntegrationSchema`.

  Handles the CalDAV-vs-OAuth branching and credential decryption internally.
  CalDAV providers decrypt credentials and create a real client via `ProviderRegistry`;
  OAuth providers use the integration struct directly as the client.

  Returns `{:ok, adapter_client()}` or `{:error, reason}`.
  """
  @spec new_client_from_integration(CalendarIntegrationSchema.t()) ::
          {:ok, adapter_client()} | {:error, term()}
  def new_client_from_integration(%CalendarIntegrationSchema{} = integration) do
    with {:ok, provider_atom} <- ProviderConfig.parse_known(integration.provider),
         {:ok, provider_module} <- ProviderRegistry.get_provider(provider_atom) do
      if ProviderConfig.caldav_based?(provider_atom) do
        decrypted = CalendarIntegrationSchema.decrypt_credentials(integration)

        config = %{
          base_url: decrypted.base_url,
          username: decrypted.username,
          password: decrypted.password,
          calendar_paths: decrypted.calendar_paths,
          verify_ssl: decrypted.verify_ssl
        }

        case ProviderRegistry.create_client(provider_atom, config, skip_validation: true) do
          {:ok, client} ->
            {:ok,
             %{
               provider_type: provider_atom,
               client: client,
               provider_module: provider_module
             }}

          {:error, _reason} = error ->
            error
        end
      else
        {:ok,
         %{
           provider_type: provider_atom,
           client: integration,
           provider_module: provider_module
         }}
      end
    end
  end

  @doc """
  Lists all events from the calendar using a wide default range (30 days ago to 365 days ahead).
  """
  @spec get_events(adapter_client()) ::
          {:ok, list()} | {:error, atom(), term()} | {:error, term()}
  def get_events(adapter_client) do
    start_time =
      DateTime.utc_now()
      |> DateTime.add(-30, :day)
      |> DateTime.truncate(:second)

    end_time =
      DateTime.utc_now()
      |> DateTime.add(365, :day)
      |> DateTime.truncate(:second)

    get_events(adapter_client, start_time, end_time)
  end

  @doc """
  Lists events within a specific date range.
  """
  @spec get_events(adapter_client(), DateTime.t(), DateTime.t()) ::
          {:ok, list()} | {:error, atom(), term()} | {:error, term()}
  def get_events(adapter_client, start_time, end_time) do
    Metrics.time_operation(
      :calendar_get_events_range,
      %{provider: adapter_client.provider_type},
      fn ->
        Logger.debug("Getting events from calendar",
          provider: adapter_client.provider_type,
          start_time: start_time,
          end_time: end_time
        )

        opts = [start_time: start_time, end_time: end_time]

        case adapter_client.provider_module.list_events(
               adapter_client.client,
               opts
             ) do
          {:ok, events} = result ->
            Logger.debug("Successfully retrieved events in range",
              provider: adapter_client.provider_type,
              event_count: length(events)
            )

            result

          {:error, type, reason} = error ->
            Logger.error("Failed to get events in range",
              provider: adapter_client.provider_type,
              error_type: type,
              reason: inspect(reason)
            )

            error

          # An %Outcome{} carries the full events list of every calendar
          # that succeeded in the round; never let it reach `inspect/1`
          # below. Log only the operational summary.
          {:error, %Outcome{} = outcome} = error ->
            Logger.error("Failed to get events in range",
              provider: adapter_client.provider_type,
              attempted: outcome.attempted,
              succeeded: outcome.succeeded,
              failed:
                Enum.map(outcome.failed, fn %{source: source, reason: reason} ->
                  %{source: source, reason: Redactor.redact_and_truncate(reason)}
                end)
            )

            error

          {:error, reason} = error ->
            Logger.error("Failed to get events in range",
              provider: adapter_client.provider_type,
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
  @spec create_event(adapter_client(), map()) ::
          {:ok, term()} | {:error, atom(), term()} | {:error, term()}
  def create_event(adapter_client, event_data) do
    Metrics.time_operation(
      :calendar_create_event,
      %{provider: adapter_client.provider_type},
      fn ->
        Logger.info("Creating event in calendar", provider: adapter_client.provider_type)

        case adapter_client.provider_module.create_event(adapter_client.client, event_data) do
          {:ok, _result} = result ->
            Logger.info("Successfully created event")
            result

          {:error, type, reason} = error ->
            Logger.error("Failed to create event",
              provider: adapter_client.provider_type,
              error_type: type,
              reason: inspect(reason)
            )

            error

          {:error, reason} = error ->
            Logger.error("Failed to create event",
              provider: adapter_client.provider_type,
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
  @spec update_event(adapter_client(), String.t(), map()) ::
          :ok | {:error, atom(), term()} | {:error, term()}
  def update_event(adapter_client, uid, event_data) do
    Metrics.time_operation(
      :calendar_update_event,
      %{provider: adapter_client.provider_type},
      fn ->
        Logger.info("Updating event in calendar",
          provider: adapter_client.provider_type,
          uid: uid
        )

        case adapter_client.provider_module.update_event(adapter_client.client, uid, event_data) do
          :ok ->
            Logger.info("Successfully updated event", uid: uid)
            :ok

          {:ok, _updated} ->
            # Be tolerant of providers that return {:ok, event}
            Logger.info("Successfully updated event", uid: uid)
            :ok

          {:error, type, reason} = error ->
            Logger.error("Failed to update event",
              provider: adapter_client.provider_type,
              error_type: type,
              uid: uid,
              reason: inspect(reason)
            )

            error

          {:error, reason} = error ->
            Logger.error("Failed to update event",
              provider: adapter_client.provider_type,
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
  @spec delete_event(adapter_client(), String.t(), keyword()) ::
          :ok | {:error, atom(), term()} | {:error, term()}
  def delete_event(adapter_client, uid, opts \\ []) do
    Metrics.time_operation(
      :calendar_delete_event,
      %{provider: adapter_client.provider_type},
      fn ->
        Logger.info("Deleting event from calendar",
          provider: adapter_client.provider_type,
          uid: uid
        )

        # CalDAV providers use the iCalendar UID natively; OAuth providers
        # (Google, Outlook) need the provider-specific event ID.
        effective_id =
          if opts[:provider_event_id] &&
               !ProviderConfig.caldav_based?(adapter_client.provider_type) do
            opts[:provider_event_id]
          else
            uid
          end

        case adapter_client.provider_module.delete_event(
               adapter_client.client,
               effective_id,
               opts
             ) do
          :ok ->
            Logger.info("Successfully deleted event", uid: uid)
            :ok

          {:ok, _deleted} ->
            # Be tolerant of providers that return {:ok, payload}
            Logger.info("Successfully deleted event", uid: uid)
            :ok

          {:error, type, reason} = error ->
            Logger.error("Failed to delete event",
              provider: adapter_client.provider_type,
              error_type: type,
              uid: uid,
              reason: inspect(reason)
            )

            error

          {:error, reason} = error ->
            Logger.error("Failed to delete event",
              provider: adapter_client.provider_type,
              uid: uid,
              reason: inspect(reason)
            )

            error
        end
      end
    )
  end
end
