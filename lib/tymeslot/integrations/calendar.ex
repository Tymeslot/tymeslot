defmodule Tymeslot.Integrations.Calendar do
  @moduledoc """
  Unified entry module for all calendar orchestration.

  - Exposes CRUD, primary selection, discovery, validation, OAuth helpers, and UI-friendly helpers
  - Adds context, validation and normalization before invoking runtime event operations
  - Replaces scattered logic from LiveComponents and bridge modules
  """

  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.DatabaseQueries.ProfileQueries
  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.DatabaseSchemas.MeetingSchema
  alias Tymeslot.DatabaseSchemas.MeetingTypeSchema
  alias Tymeslot.Integrations.Calendar.Connection
  alias Tymeslot.Integrations.Calendar.Creation
  alias Tymeslot.Integrations.Calendar.Deletion
  alias Tymeslot.Integrations.Calendar.Discovery
  alias Tymeslot.Integrations.Calendar.OAuth
  alias Tymeslot.Integrations.Calendar.Orchestration.Workflows
  alias Tymeslot.Integrations.Calendar.Runtime.EventQueries
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Integrations.Calendar.TokenUtils
  alias Tymeslot.Integrations.{CalendarManagement, CalendarPrimary}
  alias Tymeslot.Integrations.Providers.Directory
  alias Tymeslot.Utils.ContextUtils
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

    integrations
    |> Enum.map(fn integration ->
      Map.put(integration, :is_primary, integration.id == primary_id)
    end)
    |> Enum.sort_by(fn integration ->
      # Sort by: primary first (true = 1, false = 0), then by is_active (desc), then by name (asc)
      # We negate is_primary and is_active to get descending order (false/0 sorts before true/1 naturally)
      {!integration.is_primary, !integration.is_active, integration.name}
    end)
  end

  @doc """
  Gets a calendar integration by ID for a user.
  """
  @spec get_integration(integration_id(), user_id()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
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

  @doc """
  Toggles a single calendar's selection state within an integration.
  """
  @spec toggle_calendar_selection(CalendarIntegrationSchema.t(), String.t() | integer()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, any()}
  def toggle_calendar_selection(integration, calendar_id) do
    current_selection =
      Enum.reduce(integration.calendar_list || [], [], fn cal, acc ->
        cid = cal["id"] || cal[:id]
        is_selected = cal["selected"] || cal[:selected] || false

        is_now_selected =
          if to_string(cid) == to_string(calendar_id), do: !is_selected, else: is_selected

        if is_now_selected, do: [to_string(cid) | acc], else: acc
      end)

    update_calendar_selection(integration, %{"selected_calendars" => current_selection})
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
      %{provider: integration.provider, type: "calendar", success: match?({:ok, _result}, result)}
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
  Initiates an asynchronous calendar list refresh for an integration.
  Discovers fresh calendars from the provider and updates the database.
  Sends {:calendar_list_refreshed, component_id, integration_id, calendars} back to the caller.
  """
  @spec refresh_calendar_list_async(integration_id(), user_id(), String.t()) :: {:ok, pid()}
  def refresh_calendar_list_async(integration_id, user_id, component_id) do
    Workflows.refresh_calendar_list_async(integration_id, user_id, component_id)
  end

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
      id when is_integer(id) and id > 0 -> EventQueries.list_events(id)
      nil -> EventQueries.list_events(nil)
      _other -> {:error, :invalid_user_id}
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

    cond do
      is_function(debug_module, 1) ->
        debug_module.(organizer_user_id)

      is_atom(debug_module) && debug_module != nil ->
        {start_date, end_date} = calculate_booking_window_range(organizer_user_id, opts)
        debug_module.get_events_for_range_fresh(organizer_user_id, start_date, end_date)

      true ->
        # Fetch events for the entire booking window
        fetch_events_for_booking_window(organizer_user_id)
    end
  end

  @doc """
  Compatibility: context-aware variant that extracts a debug calendar module and organizer profile if present.
  """
  @spec get_calendar_events_from_context(any(), user_id(), map() | nil) ::
          {:ok, list()} | {:error, term()}
  def get_calendar_events_from_context(date, organizer_user_id, context) do
    debug_module =
      if val = ContextUtils.get_from_context(context, :debug_calendar_module) do
        val
      else
        # Try to get from config for tests
        Application.get_env(:tymeslot, :calendar_module)
      end

    opts = [
      debug_calendar_module: debug_module,
      organizer_profile: ContextUtils.get_from_context(context, :organizer_profile)
    ]

    get_calendar_events(date, organizer_user_id, opts)
  end

  @doc """
  Get events for a month with user context (preferred variant).
  """
  @spec get_events_for_month(user_id(), pos_integer(), pos_integer(), String.t()) ::
          {:ok, list()} | {:error, term()}
  def get_events_for_month(user_id, year, month, timezone)
      when is_integer(user_id) and is_integer(year) and is_integer(month) and is_binary(timezone) do
    behaviour_module().get_events_for_month(user_id, year, month, timezone)
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
    behaviour_module().get_events_for_range_fresh(user_id, start_date, end_date)
  end

  @doc """
  Create an event using the user's booking calendar.

  Accepts a user_id, Meeting, or MeetingType to determine the target calendar.
  If a Meeting or MeetingType is provided, uses their configured calendar integration.
  Falls back to the user's primary calendar if not specified.
  """
  @spec create_event(map(), user_id() | MeetingSchema.t() | MeetingTypeSchema.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def create_event(event_data, context \\ nil) do
    case context do
      id when is_integer(id) and id > 0 ->
        behaviour_module().create_event(event_data, id)

      %MeetingSchema{} = meeting ->
        behaviour_module().create_event(event_data, meeting)

      %MeetingTypeSchema{} = meeting_type ->
        behaviour_module().create_event(event_data, meeting_type)

      nil ->
        behaviour_module().create_event(event_data, nil)

      _other ->
        {:error, :invalid_context}
    end
  end

  @doc """
  Update an event with optional target integration, meeting context, or user_id.
  """
  @spec update_event(
          String.t(),
          map(),
          pos_integer() | MeetingSchema.t() | {pos_integer(), pos_integer()} | nil
        ) ::
          :ok | {:error, term()}
  def update_event(uid, event_data, context \\ nil) do
    behaviour_module().update_event(uid, event_data, context)
  end

  @doc """
  Delete an event with optional target integration, meeting context, or user_id.
  """
  @spec delete_event(
          String.t(),
          pos_integer() | MeetingSchema.t() | {pos_integer(), pos_integer()} | nil
        ) ::
          :ok | {:error, term()}
  def delete_event(uid, context \\ nil) do
    behaviour_module().delete_event(uid, context)
  end

  @doc """
  Get a single event by UID.
  """
  @spec get_event(String.t(), user_id() | nil) :: {:ok, map()} | {:error, :not_found | term()}
  def get_event(uid, user_id \\ nil), do: behaviour_module().get_event(uid, user_id)

  @doc """
  Returns the booking calendar integration info for a user or meeting type (id and path) used for event creation.
  """
  @spec get_booking_integration_info(
          pos_integer()
          | Tymeslot.DatabaseSchemas.MeetingTypeSchema.t()
        ) ::
          {:ok, %{integration_id: pos_integer(), calendar_path: String.t()}} | {:error, term()}
  def get_booking_integration_info(context) do
    behaviour_module().get_booking_integration_info(context)
  end

  # --- private helpers ---

  # Returns the configured CalendarBehaviour implementation module
  # Defaults to Operations but can be overridden for testing
  defp behaviour_module do
    mod =
      Application.get_env(
        :tymeslot,
        :calendar_module,
        Tymeslot.Integrations.Calendar.Operations
      )

    if Code.ensure_loaded?(mod) do
      mod
    else
      Logger.warning("Configured calendar_module is not loaded, falling back to Operations",
        calendar_module: inspect(mod)
      )

      Tymeslot.Integrations.Calendar.Operations
    end
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
  Discover calendars and update the integration with merged selection state.
  Persists the updated calendar_list to the database.

  Preserves existing selection state if discovery returns empty but integration
  previously had calendars selected, to prevent accidental data loss.
  """
  @spec update_integration_with_discovery(map()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, term()}
  def update_integration_with_discovery(integration) do
    Workflows.update_integration_with_discovery(integration)
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
      _other -> "Failed to connect to calendar. Please try again or reconnect."
    end
  end

  @doc """
  Format provider display name for UI consumption.
  """
  @spec format_provider_display_name(String.t()) :: String.t()
  def format_provider_display_name(provider) do
    IntegrationProviders.format_provider_name(:calendar, provider)
  end

  @doc """
  Helper to extract a friendly display name from a calendar.
  Handles the case where Radicale calendars may have UUIDs as names.
  """
  @spec extract_calendar_display_name(map()) :: String.t()
  def extract_calendar_display_name(calendar) do
    raw_name = calendar["name"] || calendar[:name]
    path = calendar["path"] || calendar[:path] || calendar["href"] || calendar[:href]
    id = calendar["id"] || calendar[:id]

    cond do
      # If name exists and doesn't look like a UUID, use it
      raw_name && !uuid_like?(raw_name) ->
        raw_name

      # If path exists, try to extract a friendly name from it
      path ->
        extract_name_from_path(path)

      # If id doesn't look like a UUID, use it
      id && !uuid_like?(id) ->
        id

      # Last resort: use the raw name even if it's a UUID
      raw_name ->
        raw_name

      true ->
        "Calendar"
    end
  end

  # Check if a string looks like a UUID
  defp uuid_like?(str) when is_binary(str) do
    String.match?(str, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
  end

  defp uuid_like?(_non_string), do: false

  # Extract a friendly name from a path like "/user/calendar-name/" -> "Calendar Name"
  defp extract_name_from_path(path) when is_binary(path) do
    segments =
      path
      |> String.split("/")
      |> Enum.reject(&(&1 == ""))

    case List.last(segments) do
      nil ->
        "Calendar"

      name ->
        name
        |> String.replace(~r/\.(ics|cal)$/, "")
        |> String.replace(["_", "-"], " ")
        |> String.split()
        |> Enum.map_join(" ", &String.capitalize/1)
    end
  end

  defp extract_name_from_path(_arg), do: "Calendar"

  @doc """
  Discovers calendars for raw credentials and filters them for valid paths.
  """
  @spec discover_and_filter_calendars(atom() | String.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{calendars: list(), discovery_credentials: map()}} | {:error, any()}
  def discover_and_filter_calendars(provider, url, username, password) do
    Workflows.discover_and_filter_calendars(provider, url, username, password)
  end

  @doc """
  Normalizes discovery errors into user-friendly strings.
  """
  @spec normalize_discovery_error(any()) :: String.t()
  def normalize_discovery_error(reason) do
    errors =
      reason
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))

    case errors do
      [] -> "Calendar discovery failed. Please check your credentials and try again."
      errors -> Enum.map_join(errors, ", ", &to_string/1)
    end
  end

  # ---------------------------
  # Public API: Webhook helpers
  # ---------------------------

  @doc """
  Finds an integration by its Google webhook channel ID.
  Used by the Google Calendar webhook controller.
  """
  @spec get_by_google_channel_id(String.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def get_by_google_channel_id(channel_id) do
    CalendarIntegrationQueries.get_by_google_channel_id(channel_id)
  end

  @doc """
  Finds an integration by its Microsoft Graph subscription ID.
  Used by the Outlook Calendar webhook and lifecycle controllers.
  """
  @spec get_by_graph_subscription_id(String.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def get_by_graph_subscription_id(subscription_id) do
    CalendarIntegrationQueries.get_by_graph_subscription_id(subscription_id)
  end

  @doc """
  Fetches all integrations matching the given Graph subscription IDs in a single query.
  Used by the Outlook webhook controller for batch notification processing.
  """
  @spec get_by_graph_subscription_ids([String.t()]) :: [CalendarIntegrationSchema.t()]
  def get_by_graph_subscription_ids(subscription_ids) do
    CalendarIntegrationQueries.get_by_graph_subscription_ids(subscription_ids)
  end

  @doc """
  Touches the notification timestamp for the given integration and field.
  Used by webhook controllers to track the last notification time.
  """
  @spec touch_notification_at(CalendarIntegrationSchema.t(), atom()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def touch_notification_at(integration, field) when is_atom(field) do
    CalendarIntegrationQueries.touch_notification_at(integration, field)
  end

  @spec fetch_events_for_booking_window(user_id()) :: {:ok, list()} | {:error, term()}
  defp fetch_events_for_booking_window(user_id) do
    {start_date, end_date} = calculate_booking_window_range(user_id)

    case ProfileQueries.get_by_user_id(user_id) do
      {:ok, _profile} ->
        get_events_for_range_fresh(user_id, start_date, end_date)

      {:error, _reason} ->
        list_events(user_id)
    end
  end

  defp calculate_booking_window_range(user_id, opts \\ []) do
    profile_result =
      case Keyword.get(opts, :organizer_profile) do
        %{} = profile -> {:ok, profile}
        nil -> ProfileQueries.get_by_user_id(user_id)
      end

    case profile_result do
      {:ok, profile} ->
        today = Date.utc_today()
        {today, Date.add(today, profile.advance_booking_days)}

      {:error, _reason} ->
        today = Date.utc_today()
        # Default fallback window
        {today, Date.add(today, 30)}
    end
  end
end
