defmodule Tymeslot.Integrations.Calendar.Runtime.ClientManager do
  @moduledoc """
  Creates and resolves calendar provider clients.

  Responsibilities:
  - Create provider-specific clients from integrations by dispatching to
    each provider's `build_client_configs/1` and `build_booking_client_config/1`
    behaviour callbacks
  - Resolve a runtime client from a Meeting/MeetingType/user-id context
  - Look up the booking integration info that the SaaS layer needs

  Booking-integration resolution and calendar-path resolution live in their
  own focused modules (`BookingIntegrationResolver` and
  `CalendarPathResolver`) and are composed here.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Providers.ProviderAdapter
  alias Tymeslot.Integrations.Calendar.Runtime.BookingIntegrationResolver
  alias Tymeslot.Integrations.Calendar.Runtime.CalendarPathResolver
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  @type user_id :: pos_integer()
  @type integration_id :: pos_integer()
  @type client :: map()

  @doc """
  Gets configured calendar clients for all calendars belonging to a user.
  Returns a list of adapter clients, one for each configured calendar path.
  """
  @spec clients(user_id() | nil) :: [client()]
  def clients(user_id \\ nil) do
    case fetch_active_integrations(user_id) do
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
  Gets configured calendar clients for a single integration.
  """
  @spec clients_for_integration(map()) :: [client()]
  def clients_for_integration(integration) do
    create_clients_from_integration(integration)
  end

  @doc """
  Gets a single configured calendar client. Uses the first configured path.
  """
  @spec client(user_id() | nil) :: client() | nil
  def client(user_id \\ nil) do
    List.first(clients(user_id))
  end

  @doc """
  Gets the calendar client for creating bookings from a Meeting,
  MeetingType, or bare user id context.
  """
  @spec booking_client(
          user_id()
          | {integration_id(), user_id()}
          | MeetingSchema.t()
          | MeetingTypeSchema.t()
          | nil
        ) ::
          client() | nil
  def booking_client(context \\ nil) do
    context
    |> BookingIntegrationResolver.resolve()
    |> create_booking_client_from_integration()
  end

  @doc """
  Returns the integration id and calendar path that will be used for
  creating bookings, given a Meeting, MeetingType, or user id.
  """
  @spec get_booking_integration_info(user_id() | MeetingSchema.t() | MeetingTypeSchema.t()) ::
          {:ok, %{integration_id: integration_id(), calendar_path: String.t()}}
          | {:error, atom()}
  def get_booking_integration_info(%MeetingSchema{} = meeting) do
    case BookingIntegrationResolver.resolve(meeting) do
      nil ->
        {:error, :no_integration}

      integration ->
        {:ok,
         %{
           integration_id: integration.id,
           calendar_path: meeting.calendar_path || CalendarPathResolver.resolve(integration)
         }}
    end
  end

  def get_booking_integration_info(%MeetingTypeSchema{} = mt) do
    case BookingIntegrationResolver.resolve(mt) do
      nil ->
        {:error, :no_integration}

      integration ->
        {:ok,
         %{
           integration_id: integration.id,
           calendar_path: mt.target_calendar_id || CalendarPathResolver.resolve(integration)
         }}
    end
  end

  def get_booking_integration_info(user_id) when is_integer(user_id) do
    case BookingIntegrationResolver.resolve(user_id) do
      nil ->
        {:error, :no_integration}

      integration ->
        {:ok,
         %{
           integration_id: integration.id,
           calendar_path: CalendarPathResolver.resolve(integration)
         }}
    end
  end

  @doc """
  Gets a client by integration ID, validating user ownership.
  """
  @spec get_client_by_integration_id(integration_id(), user_id()) :: client() | nil
  def get_client_by_integration_id(integration_id, user_id) do
    case CalendarManagement.fetch_integration_for_user(integration_id, user_id) do
      {:error, :not_found} ->
        nil

      {:ok, integration} ->
        booking_client_for_integration(integration)
    end
  end

  @doc """
  Resolves a calendar client from various context types.
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

      _other ->
        client()
    end
  end

  # --- Private Implementation ---

  defp create_clients_from_integration(integration) do
    with {:ok, provider} <- ProviderConfig.parse_known(integration.provider),
         provider_module when is_atom(provider_module) and provider_module != nil <-
           ProviderConfig.get_provider_module(provider),
         true <- function_exported?(provider_module, :build_client_configs, 1) do
      provider_module.build_client_configs(integration)
      |> Enum.map(&create_adapter_client(provider, &1))
      |> Enum.reject(&is_nil/1)
    else
      _other ->
        Logger.warning("Unknown or unsupported calendar provider",
          provider: inspect(integration.provider)
        )

        []
    end
  end

  defp create_booking_client_from_integration(nil), do: nil

  defp create_booking_client_from_integration(integration) do
    booking_client_for_integration(integration)
  end

  defp booking_client_for_integration(integration) do
    with {:ok, provider} <- ProviderConfig.parse_known(integration.provider),
         provider_module when is_atom(provider_module) and provider_module != nil <-
           ProviderConfig.get_provider_module(provider),
         true <- function_exported?(provider_module, :build_booking_client_config, 1),
         %{} = config <- provider_module.build_booking_client_config(integration) do
      create_adapter_client(provider, config)
    else
      _other -> nil
    end
  end

  defp create_adapter_client(provider_type, config) do
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

  defp fetch_active_integrations(nil), do: {:error, :user_id_required}

  defp fetch_active_integrations(user_id) do
    case CalendarManagement.list_active_calendar_integrations(user_id) do
      [] -> :not_found
      integrations -> {:ok, integrations}
    end
  end
end
