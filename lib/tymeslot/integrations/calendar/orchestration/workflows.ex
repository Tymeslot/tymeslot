defmodule Tymeslot.Integrations.Calendar.Orchestration.Workflows do
  @moduledoc """
  Complex multi-step calendar workflows.

  Responsibilities:
  - Asynchronous calendar list refresh workflows
  - Integration discovery and update pipelines
  - Discovery with filtering and validation
  """

  require Logger
  alias Tymeslot.Integrations.Calendar.Discovery
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Integrations.CalendarManagement

  @type user_id :: pos_integer()
  @type integration_id :: pos_integer()

  @doc """
  Initiates an asynchronous calendar list refresh for an integration.
  Discovers fresh calendars from the provider and updates the database.
  Sends {:calendar_list_refreshed, component_id, integration_id, calendars} back to the caller.
  """
  @spec refresh_calendar_list_async(integration_id(), user_id(), String.t()) :: {:ok, pid()}
  def refresh_calendar_list_async(integration_id, user_id, component_id) do
    parent = self()

    Logger.info("Starting async calendar list refresh",
      integration_id: integration_id,
      user_id: user_id
    )

    Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
      case CalendarManagement.get_calendar_integration(integration_id, user_id) do
        {:ok, integration} ->
          case Discovery.discover_calendars_for_integration(integration) do
            {:ok, calendars} ->
              Logger.info("Successfully discovered calendars",
                integration_id: integration_id,
                count: length(calendars)
              )

              # Update the integration's calendar_list in the database so it's persisted
              case CalendarManagement.update_calendar_integration(integration, %{
                     calendar_list: calendars
                   }) do
                {:ok, _integration} ->
                  send(
                    parent,
                    {:calendar_list_refreshed, component_id, integration_id, calendars}
                  )

                {:error, reason} ->
                  Logger.error("Failed to persist calendar list",
                    integration_id: integration_id,
                    error: inspect(reason)
                  )

                  send(
                    parent,
                    {:calendar_list_refreshed, component_id, integration_id,
                     integration.calendar_list}
                  )
              end

            {:error, reason} ->
              Logger.error("Failed to discover calendars",
                integration_id: integration_id,
                error: inspect(reason)
              )

              send(
                parent,
                {:calendar_list_refreshed, component_id, integration_id,
                 integration.calendar_list}
              )
          end

        {:error, reason} ->
          Logger.error("Failed to find integration for calendar refresh",
            integration_id: integration_id,
            error: inspect(reason)
          )

          send(parent, {:calendar_list_refreshed, component_id, integration_id, []})
      end
    end)
  end

  @doc """
  Discover calendars and update the integration with merged selection state.
  Persists the updated calendar_list to the database.

  Preserves existing selection state if discovery returns empty but integration
  previously had calendars selected, to prevent accidental data loss.
  """
  @spec update_integration_with_discovery(map()) ::
          {:ok, Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t()} | {:error, term()}
  def update_integration_with_discovery(integration) do
    with {:ok, refreshed_integration} <- refresh_integration(integration),
         {:ok, merged} <- Selection.discover_with_selection(refreshed_integration) do
      # If discovery returned empty but we had existing selection, preserve it
      # to prevent accidental data loss from transient provider issues
      existing_calendar_list = refreshed_integration.calendar_list
      had_existing_selection = existing_calendar_list != []

      final_calendar_list =
        if merged == [] && had_existing_selection do
          existing_calendar_list
        else
          merged
        end

      case CalendarManagement.update_calendar_integration(refreshed_integration, %{
             calendar_list: final_calendar_list
           }) do
        {:ok, updated} -> {:ok, updated}
        error -> error
      end
    else
      error ->
        error
    end
  end

  @doc """
  Discovers calendars for raw credentials and filters them for valid paths.
  """
  @spec discover_and_filter_calendars(atom() | String.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{calendars: list(), discovery_credentials: map()}} | {:error, any()}
  def discover_and_filter_calendars(provider, url, username, password) do
    case Discovery.discover_calendars_for_credentials(provider, url, username, password,
           force_refresh: true
         ) do
      {:ok, %{calendars: calendars, discovery_credentials: credentials}} ->
        # Filter calendars to only include those with valid paths
        valid_calendars =
          Enum.filter(calendars, fn calendar ->
            is_binary(calendar[:path] || calendar[:href])
          end)

        {:ok, %{calendars: valid_calendars, discovery_credentials: credentials}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private Helpers ---

  defp refresh_integration(%{id: id, user_id: user_id} = _integration)
       when is_integer(id) and is_integer(user_id) do
    case CalendarManagement.get_calendar_integration(id, user_id) do
      {:ok, fresh} -> {:ok, fresh}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp refresh_integration(integration), do: {:ok, integration}
end
