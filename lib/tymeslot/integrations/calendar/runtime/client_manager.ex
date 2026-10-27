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

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.AvailabilityView
  alias Tymeslot.Integrations.Calendar.BookingEligibility
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Providers.ProviderAdapter
  alias Tymeslot.Integrations.Calendar.Runtime.BookingIntegrationResolver
  alias Tymeslot.Integrations.Calendar.Runtime.CalendarPathResolver
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  @type user_id :: pos_integer()
  @type integration_id :: pos_integer()
  @type client :: map()

  @doc """
  The clients that read a user's calendars for availability: those of
  `availability_sources/1`, without the ids of unreadable integrations. A
  calendar set to show only gets none (see `AvailabilityView.of/1`);
  for every calendar the user has, use `clients_for_integration/1`.
  """
  @spec clients(user_id() | nil) :: [client()]
  def clients(user_id) do
    {clients, _unreadable_ids} = availability_sources(user_id)
    clients
  end

  @doc """
  The clients that read the user's blocking calendars, plus the ids of the
  active integrations with a blocking calendar whose credentials no longer
  decrypt.

  Each integration is read through `AvailabilityView.of/1`, so a
  calendar set to show only gets no client and can never refuse a slot, and
  an integration with nothing blocking contributes none at all. The
  availability check must count an undecryptable integration as a calendar
  it could not read rather than one with no events, so those ids are
  returned rather than dropped; its calendar list is stored unencrypted, so
  one whose calendars all show only is left out instead.
  """
  @spec availability_sources(user_id() | nil) :: {[client()], [integration_id()]}
  def availability_sources(user_id) do
    case fetch_active_integrations(user_id) do
      {:ok, integrations, unreadable} ->
        clients =
          integrations
          |> Enum.map(&AvailabilityView.of/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.flat_map(&clients_for_integration/1)

        {clients, for(i <- unreadable, AvailabilityView.of(i) != nil, do: i.id)}

      :not_found ->
        Logger.warning(
          "No calendar integrations configured. Please add calendar integrations in the dashboard."
        )

        {[], []}

      {:error, :user_id_required} ->
        Logger.warning(
          "User ID is required for calendar operations. Please ensure user context is available."
        )

        {[], []}
    end
  end

  @doc """
  Gets configured calendar clients for a single integration.
  """
  @spec clients_for_integration(map()) :: [client()]
  def clients_for_integration(integration) do
    create_clients_from_integration(integration, fn _config -> true end)
  end

  @doc """
  The clients of `clients_for_integration/1` for calendars the organiser can
  write to.

  A read-only calendar the organiser selected gets a read client so that its
  events block time, but an event Tymeslot wrote can never be in it, so a
  search for one leaves it out.
  """
  @spec writable_clients_for_integration(map()) :: [client()]
  def writable_clients_for_integration(integration) do
    create_clients_from_integration(integration, &write_target?/1)
  end

  @doc """
  The client a write for `user_id` falls back to when nothing names an
  integration: the user's booking client, or failing that the first writable
  calendar of an integration that can take bookings and whose credentials
  have not been refused. Never a read-only calendar or a subscribed feed,
  which `clients/1` includes so that their events block time, but which take
  no writes.
  """
  @spec client(user_id() | nil) :: client() | nil
  def client(user_id \\ nil) do
    booking_client(user_id) || first_writable_client(user_id)
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
           calendar_path:
             booking_calendar_path(
               meeting.calendar_integration_id,
               meeting.calendar_path,
               integration
             )
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
           calendar_path:
             booking_calendar_path(mt.calendar_integration_id, mt.target_calendar_id, integration)
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
    case Management.fetch_integration_for_user(integration_id, user_id) do
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

  # The calendar a meeting or meeting type recorded belongs to the integration
  # it recorded. Once resolution has fallen through to another integration,
  # that calendar id names nothing there, so the fallback's own booking
  # calendar is used instead of carrying a foreign id onto it.
  defp booking_calendar_path(stored_id, stored_path, %{id: stored_id})
       when is_binary(stored_path),
       do: stored_path

  defp booking_calendar_path(_stored_id, _stored_path, integration),
    do: CalendarPathResolver.resolve(integration)

  defp create_clients_from_integration(integration, keep?) do
    with {:ok, provider} <- ProviderConfig.parse_known(integration.provider),
         provider_module when is_atom(provider_module) and provider_module != nil <-
           ProviderConfig.get_provider_module(provider),
         true <- callback_exported?(provider_module, :build_client_configs, 1) do
      # Optional callback resolved at runtime via the guard above; apply/3
      # keeps the static type checker from flagging providers that omit it.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(provider_module, :build_client_configs, [integration])
      |> Enum.filter(keep?)
      |> Enum.map(&create_adapter_client(provider, &1))
      |> Enum.reject(&is_nil/1)
    else
      _other ->
        Logger.warning("Unknown or unsupported calendar provider",
          provider: LogFormat.reason(integration.provider)
        )

        []
    end
  end

  # A CalDAV config names its own collection and the integration's writable
  # ones (`ProviderCommon.caldav_build_client_configs/1`); it is compared
  # before `new/1`, which may rewrite the collection into the server's form.
  # Any other provider's client reaches the whole account.
  defp write_target?(%{calendar_path: path, writable_calendar_paths: writable})
       when is_list(writable),
       do: path in writable

  defp write_target?(_config), do: true

  defp create_booking_client_from_integration(nil), do: nil

  defp create_booking_client_from_integration(integration) do
    booking_client_for_integration(integration)
  end

  defp booking_client_for_integration(integration) do
    with {:ok, provider} <- ProviderConfig.parse_known(integration.provider),
         provider_module when is_atom(provider_module) and provider_module != nil <-
           ProviderConfig.get_provider_module(provider),
         true <- callback_exported?(provider_module, :build_booking_client_config, 1),
         # credo:disable-for-next-line Credo.Check.Refactor.Apply
         %{} = config <- apply(provider_module, :build_booking_client_config, [integration]) do
      create_adapter_client(provider, config)
    else
      _other -> nil
    end
  end

  # function_exported?/3 returns false for modules that haven't been loaded yet,
  # which silently turns optional callbacks into no-ops. Force-load first so the
  # check reflects what the module actually exports.
  defp callback_exported?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
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

  # Only an integration a booking could be written to: never a subscribed
  # feed (whose single calendar `write_target?/1` cannot tell from a writable
  # one), nor one whose credentials were refused.
  defp first_writable_client(user_id) do
    case fetch_active_integrations(user_id) do
      {:ok, integrations, _unreadable} ->
        integrations
        |> Enum.filter(&(BookingEligibility.bookable?(&1) and &1.needs_reauth != true))
        |> Enum.find_value(&List.first(writable_clients_for_integration(&1)))

      _none ->
        nil
    end
  end

  defp fetch_active_integrations(nil), do: {:error, :user_id_required}

  defp fetch_active_integrations(user_id) do
    case Management.partition_active_calendar_integrations(user_id) do
      {[], []} -> :not_found
      {integrations, unreadable} -> {:ok, integrations, unreadable}
    end
  end
end
