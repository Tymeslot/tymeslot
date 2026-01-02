defmodule Tymeslot.Integrations.Calendar do
  @moduledoc """
  Unified entry module for all calendar orchestration.

  - Exposes CRUD, primary selection, discovery, validation, OAuth helpers, and UI-friendly helpers
  - Adds context, validation and normalization before invoking runtime event operations
  - Replaces scattered logic from LiveComponents and bridge modules
  """

  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.DatabaseQueries.ProfileQueries
  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Connection
  alias Tymeslot.Integrations.Calendar.Creation
  alias Tymeslot.Integrations.Calendar.Deletion
  alias Tymeslot.Integrations.Calendar.Discovery
  alias Tymeslot.Integrations.Calendar.OAuth
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Integrations.Calendar.TokenUtils
  alias Tymeslot.Integrations.{CalendarManagement, CalendarPrimary}
  alias Tymeslot.Integrations.Providers.Directory
  alias TymeslotWeb.Helpers.IntegrationProviders

  require Logger

  @type user_id :: pos_integer()
  @type integration_id :: pos_integer()

  # ---------------------------
  # Public API: Listing/CRUD
  # ---------------------------

  @doc """
  Lists calendar integrations for a user and annotates the primary one.
  """
  @spec list_integrations(user_id()) :: [map()]
  def list_integrations(user_id) when is_integer(user_id) do
    integrations = CalendarManagement.list_calendar_integrations(user_id)

    primary_id =
      case CalendarPrimary.get_primary_calendar_integration(user_id) do
        {:ok, primary} -> primary.id
        {:error, :not_found} -> nil
        {:error, :no_primary_set} -> nil
      end

    Enum.map(integrations, fn integration ->
      Map.put(integration, :is_primary, integration.id == primary_id)
    end)
  end

  @doc """
  Gets a calendar integration by ID for a user.
  """
  @spec get_integration(integration_id(), user_id()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found | :unauthorized}
  def get_integration(id, user_id) when is_integer(id) and is_integer(user_id) do
    CalendarManagement.get_calendar_integration(id, user_id)
  end

  @doc """
  Creates a new calendar integration, with provider-specific parsing and optional pre-validation.
  """
  @spec create_integration(map(), user_id()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t() | any()}
  def create_integration(params, user_id) when is_map(params) and is_integer(user_id) do
    with {:ok, attrs} <- Creation.prepare_attrs(params, user_id),
         {:ok, attrs} <- Creation.prevalidate_config(attrs) do
      CalendarManagement.create_calendar_integration(attrs)
    end
  end

  @doc """
  Updates an existing calendar integration.
  """
  @spec update_integration(CalendarIntegrationSchema.t(), map()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_integration(integration, attrs) do
    CalendarManagement.update_calendar_integration(integration, attrs)
  end

  @doc """
  Toggles active status of an integration by ID for a user.
  Ensures primary reassignment is handled atomically.
  """
  @spec toggle_integration(integration_id(), user_id()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, any()}
  def toggle_integration(id, user_id) do
    with {:ok, integration} <- CalendarManagement.get_calendar_integration(id, user_id) do
      CalendarManagement.toggle_with_primary_rebalance(integration)
    end
  end

  @doc """
  Deletes an integration by ID for a user. Handles primary reassignment internally.
  """
  @spec delete_integration(integration_id(), user_id()) :: {:ok, any()} | {:error, any()}
  def delete_integration(id, user_id) do
    with {:ok, integration} <- CalendarManagement.get_calendar_integration(id, user_id) do
      CalendarManagement.delete_calendar_integration(integration)
    end
  end

  @doc """
  Sets the primary calendar integration for a user.
  """
  @spec set_primary(user_id(), integration_id()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, any()}
  def set_primary(user_id, integration_id),
    do: CalendarPrimary.set_primary_calendar_integration(user_id, integration_id)

  @doc """
  Clears the primary calendar integration for a user.
  """
  @spec clear_primary(user_id()) :: {:ok, any()} | {:error, any()}
  def clear_primary(user_id) do
    ProfileQueries.clear_primary_calendar_integration(user_id)
  end

  # ---------------------------
  # Public API: Discovery/Selection
  # ---------------------------

  @doc """
  Discovers calendars for the given integration using provider-specific logic.
  Returns {:ok, calendars} with standardized calendar entries.
  """
  @spec discover_calendars_for_integration(map()) :: {:ok, list()} | {:error, any()}
  def discover_calendars_for_integration(integration) do
    Discovery.discover_calendars_for_integration(integration)
  end

  @doc """
  Updates the calendar selection for an integration, optionally setting explicit default.
  """
  @spec update_calendar_selection(CalendarIntegrationSchema.t(), map()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, any()}
  def update_calendar_selection(integration, params) do
    Selection.update_calendar_selection(integration, params)
  end

  # ---------------------------
  # Public API: Validation/Connection
  # ---------------------------

  @doc """
  Validates that an integration can connect to its provider.
  Returns {:ok, integration} or {:error, reason}.
  """
  @spec validate_connection(CalendarIntegrationSchema.t(), user_id()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, any()}
  def validate_connection(integration, user_id) do
    Connection.validate_connection(integration, user_id)
  end

  @doc """
  Tests the connection and returns display-friendly message.
  Delegates to Connection.test_connection/1 to centralize provider resolution.
  """
  @spec test_connection(CalendarIntegrationSchema.t()) :: {:ok, String.t()} | {:error, any()}
  def test_connection(integration) do
    start_time = System.monotonic_time(:millisecond)

    result = Connection.test_connection(integration)

    duration = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute(
      [:tymeslot, :integration, :test_connection],
      %{duration: duration},
      %{provider: integration.provider, type: "calendar", success: match?({:ok, _}, result)}
    )

    result
  end

  # ---------------------------
  # Public API: Higher-level wrappers (submodules)
  # ---------------------------

  @doc """
  Validates and creates an integration through the creation pipeline.
  """
  @spec create_integration_with_validation(user_id(), map(), keyword()) ::
          {:ok, CalendarIntegrationSchema.t()}
          | {:error, {:form_errors, map()} | {:changeset, Ecto.Changeset.t()} | any()}
  def create_integration_with_validation(user_id, params, opts \\ []) do
    Creation.create_with_validation(user_id, params, opts)
  end

  @doc """
  Prepare selection params from selected paths and discovered calendars.
  """
  @spec prepare_selection_params([String.t()], list()) :: map()
  def prepare_selection_params(selected_paths, discovered) do
    Selection.prepare_selected_params(selected_paths, discovered)
  end

  @doc """
  Discover calendars and merge with existing selection state for an integration.
  """
  @spec discover_calendars_with_selection(map()) :: {:ok, list()} | {:error, any()}
  def discover_calendars_with_selection(integration) do
    Selection.discover_with_selection(integration)
  end

  @doc """
  Validate a connection with a timeout wrapper.
  """
  @spec validate_connection_with_timeout(CalendarIntegrationSchema.t(), user_id(), keyword()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, any()}
  def validate_connection_with_timeout(integration, user_id, opts \\ []) do
    Connection.validate(integration, user_id, opts)
  end

  @doc """
  Delete integration while reassigning/clearing primary as needed.
  """
  @spec delete_with_primary_reassignment(user_id(), integration_id()) ::
          {:ok, any()} | {:error, any()}
  def delete_with_primary_reassignment(user_id, id) do
    Deletion.delete_with_primary_reassignment(user_id, id)
  end

  @doc """
  Delete integration and invalidate dashboard cache for the user.
  Wraps delete_with_primary_reassignment/2 and triggers downstream invalidation.
  """
  @spec delete_with_primary_reassignment_and_invalidate(user_id(), integration_id()) ::
          {:ok, any()} | {:error, any()}
  def delete_with_primary_reassignment_and_invalidate(user_id, id) do
    case delete_with_primary_reassignment(user_id, id) do
      {:ok, result} ->
        DashboardContext.invalidate_integration_status(user_id)
        {:ok, result}

      error ->
        error
    end
  end

  # ---------------------------
  # Public API: OAuth helpers
  # ---------------------------

  @doc """
  Initiates Google Calendar OAuth flow and returns the authorization URL.
  """
  @spec initiate_google_oauth(user_id()) :: {:ok, String.t()} | {:error, String.t()}
  def initiate_google_oauth(user_id) when is_integer(user_id) do
    OAuth.initiate_google_oauth(user_id)
  end

  @doc """
  Initiates Outlook Calendar OAuth flow and returns the authorization URL.
  """
  @spec initiate_outlook_oauth(user_id()) :: {:ok, String.t()} | {:error, String.t()}
  def initiate_outlook_oauth(user_id) when is_integer(user_id) do
    OAuth.initiate_outlook_oauth(user_id)
  end

  @doc """
  Initiates a Google scope upgrade for an existing integration.
  Validates the integration belongs to the user and is a Google provider.
  Returns the authorization URL for the upgrade flow.
  """
  @spec initiate_google_scope_upgrade(user_id(), integration_id()) ::
          {:ok, String.t()} | {:error, any()}
  def initiate_google_scope_upgrade(user_id, integration_id)
      when is_integer(user_id) and is_integer(integration_id) do
    OAuth.initiate_google_scope_upgrade(user_id, integration_id)
  end

  # ---------------------------
  # Public API: UI helpers
  # ---------------------------

  @doc """
  Formats token expiry info into a human-readable string.
  """
  @spec format_token_expiry(map()) :: String.t()
  def format_token_expiry(integration) do
    case TokenUtils.format_token_expiry(integration) do
      {_status, message} -> message
    end
  end

  @doc """
  Checks if a Google integration needs scope upgrade.
  """
  @spec needs_scope_upgrade?(map()) :: boolean()
  def needs_scope_upgrade?(integration) do
    OAuth.needs_scope_upgrade?(integration)
  end

  # ---------------------------
  # Runtime calendar operations with added context/validation
  # ---------------------------

  @doc """
  List events for a user. If user_id is nil, falls back to runtime behavior.
  """
  @spec list_events(user_id() | nil) :: {:ok, list()} | {:error, term()}
  def list_events(user_id \\ nil) do
    case user_id do
      id when is_integer(id) and id > 0 -> Operations.list_events(id)
      nil -> Operations.list_events(nil)
      _ -> {:error, :invalid_user_id}
    end
  end

  @doc """
  Fetch calendar events for the user's entire booking window.

  This ensures that all events within the advance booking period are available
  for conflict checking, not just the current month.

  Falls back to list_events if profile cannot be loaded.
  """
  @spec get_calendar_events(Date.t() | any(), user_id(), keyword()) ::
          {:ok, list()} | {:error, term()}
  def get_calendar_events(_date, organizer_user_id, opts \\ []) do
    debug_module = Keyword.get(opts, :debug_calendar_module)

    if is_function(debug_module, 1) do
      debug_module.(organizer_user_id)
    else
      # Fetch events for the entire booking window
      fetch_events_for_booking_window(organizer_user_id)
    end
  end

  @doc """
  Compatibility: socket-aware variant that extracts a debug calendar module if present.
  """
  @spec get_calendar_events_from_socket(any(), user_id(), map() | nil) ::
          {:ok, list()} | {:error, term()}
  def get_calendar_events_from_socket(date, organizer_user_id, socket) do
    debug_module =
      if socket && Map.has_key?(socket, :private) && socket.private[:debug_calendar_module] do
        socket.private[:debug_calendar_module]
      else
        nil
      end

    get_calendar_events(date, organizer_user_id, debug_calendar_module: debug_module)
  end

  @doc """
  Get events for a month with user context (preferred variant).
  """
  @spec get_events_for_month(user_id(), pos_integer(), pos_integer(), String.t()) ::
          {:ok, list()} | {:error, term()}
  def get_events_for_month(user_id, year, month, timezone)
      when is_integer(user_id) and is_integer(year) and is_integer(month) and is_binary(timezone) do
    Operations.get_events_for_month(user_id, year, month, timezone)
  end

  @doc """
  Backward-compatible variant without explicit user context.
  """
  @spec get_events_for_month(pos_integer(), pos_integer(), String.t()) ::
          {:ok, list()} | {:error, term()}
  def get_events_for_month(_year, _month, _timezone),
    do: {:error, :user_id_required}

  @doc """
  Get fresh events for range with user context (preferred variant).
  """
  @spec get_events_for_range_fresh(user_id(), Date.t(), Date.t()) ::
          {:ok, list()} | {:error, term()}
  def get_events_for_range_fresh(user_id, start_date, end_date)
      when is_integer(user_id) do
    Operations.get_events_for_range_fresh(user_id, start_date, end_date)
  end

  @doc """
  Create an event using the user's booking calendar.
  """
  @spec create_event(map(), user_id() | nil) :: {:ok, map()} | {:error, term()}
  def create_event(event_data, user_id \\ nil) do
    case user_id do
      id when is_integer(id) and id > 0 -> Operations.create_event(event_data, id)
      nil -> Operations.create_event(event_data, nil)
      _ -> {:error, :invalid_user_id}
    end
  end

  @doc """
  Update an event with optional target integration.
  """
  @spec update_event(String.t(), map(), pos_integer() | nil) :: :ok | {:error, term()}
  def update_event(uid, event_data, calendar_integration_id \\ nil) do
    Operations.update_event(uid, event_data, calendar_integration_id)
  end

  @doc """
  Delete an event with optional target integration.
  """
  @spec delete_event(String.t(), pos_integer() | nil) :: :ok | {:error, term()}
  def delete_event(uid, calendar_integration_id \\ nil) do
    Operations.delete_event(uid, calendar_integration_id)
  end

  @doc """
  Get a single event by UID.
  """
  @spec get_event(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_event(uid), do: Operations.get_event(uid)

  @doc """
  Returns the booking calendar integration info for a user (id and path) used for event creation.
  """
  @spec get_booking_integration_info(pos_integer()) ::
          {:ok, %{integration_id: pos_integer(), calendar_path: String.t()}} | {:error, term()}
  def get_booking_integration_info(user_id) when is_integer(user_id) do
    Operations.get_booking_integration_info(user_id)
  end

  # ---------------------------
  # Additional orchestrator helpers for UI and management
  # ---------------------------

  @doc """
  List available providers for calendar integrations.
  """
  @spec list_available_providers(atom()) :: list()
  def list_available_providers(type \\ :calendar) do
    Directory.list(type)
  end

  @doc """
  Discover calendars and return the integration with merged selection state.
  """
  @spec update_integration_with_discovery(map()) :: {:ok, map()} | {:error, term()}
  def update_integration_with_discovery(integration) do
    case discover_calendars_with_selection(integration) do
      {:ok, merged} -> {:ok, %{integration | calendar_list: merged}}
      error -> error
    end
  end

  @doc """
  Discovers calendars for raw credentials before creating an integration.
  Delegates to Tymeslot.Integrations.Calendar.Discovery for a single source of truth.
  """
  @spec discover_calendars_for_credentials(
          atom() | String.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, %{calendars: list(), discovery_credentials: map()}} | {:error, String.t()}
  def discover_calendars_for_credentials(provider, url, username, password, opts \\ []) do
    Discovery.discover_calendars_for_credentials(provider, url, username, password, opts)
  end

  @doc """
  Map connection/validation error atoms to user-friendly messages.
  """
  @spec connection_error_message(term()) :: String.t()
  def connection_error_message(reason) do
    case reason do
      :timeout -> "Calendar service is not responding. Please try again later."
      :authentication_failed -> "Authentication failed. Please reconnect your calendar."
      :token_expired -> "Your calendar access has expired. Please reconnect."
      :network_error -> "Unable to reach calendar service. Check your internet connection."
      :invalid_credentials -> "Invalid calendar credentials. Please update your connection."
      _ -> "Failed to connect to calendar. Please try again or reconnect."
    end
  end

  @doc """
  Format provider display name for UI consumption.
  """
  @spec format_provider_display_name(String.t()) :: String.t()
  def format_provider_display_name(provider) do
    IntegrationProviders.format_provider_name(:calendar, provider)
  end

  # ---------------------------
  # Internal helpers (legacy) — moved to dedicated modules
  # ---------------------------

  @doc false
  @spec fetch_events_for_booking_window(user_id()) :: {:ok, list()} | {:error, term()}
  defp fetch_events_for_booking_window(user_id) do
    # Get user's profile to determine booking window
    case ProfileQueries.get_by_user_id(user_id) do
      {:ok, profile} ->
        today = Date.utc_today()
        # Fetch events from today through the entire booking window
        end_date = Date.add(today, profile.advance_booking_days)

        get_events_for_range_fresh(user_id, today, end_date)

      {:error, _reason} ->
        # Fallback to list_events if profile not found
        # This maintains backward compatibility
        list_events(user_id)
    end
  end
end
