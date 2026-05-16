defmodule Tymeslot.Integrations.Calendar do
  @moduledoc """
  Integration management for calendar providers.

  Owns CRUD, primary selection, discovery, validation, OAuth helpers,
  and UI-friendly helpers for calendar integrations.

  For calendar event operations (list, create, update, delete events),
  see `Tymeslot.Integrations.Calendar.Events`.

  For webhook lookup and notification tracking,
  see `Tymeslot.Integrations.Calendar.Webhooks`.
  """

  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Connection
  alias Tymeslot.Integrations.Calendar.Creation
  alias Tymeslot.Integrations.Calendar.Deletion
  alias Tymeslot.Integrations.Calendar.Discovery
  alias Tymeslot.Integrations.Calendar.EventsRead
  alias Tymeslot.Integrations.Calendar.OAuth
  alias Tymeslot.Integrations.Calendar.Orchestration.Workflows
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Providers.{CaldavCommon, ProviderAdapter}
  alias Tymeslot.Integrations.Calendar.Reconnection
  alias Tymeslot.Integrations.Calendar.Runtime.ClientManager
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Integrations.Calendar.TokenUtils
  alias Tymeslot.Integrations.{CalendarManagement, CalendarPrimary}
  alias Tymeslot.Integrations.Providers.Directory
  alias Tymeslot.Profiles.ProfileQueries

  @type user_id :: pos_integer()
  @type integration_id :: pos_integer()
  @type integration :: CalendarIntegrationSchema.t()
  @type calendar_selection_params :: %{required(:selected_calendars) => [String.t()]}

  # ---------------------------
  # Public API: Listing/CRUD
  # ---------------------------

  @doc """
  Lists calendar integrations for a user and annotates the primary one.
  """
  @spec list_integrations(user_id()) :: [integration()]
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

  @doc "Gets a calendar integration by ID for a user."
  @spec get_integration(integration_id(), user_id()) ::
          {:ok, integration()} | {:error, :not_found}
  def get_integration(id, user_id) when is_integer(id) and is_integer(user_id) do
    CalendarManagement.get_calendar_integration(id, user_id)
  end

  @doc """
  Creates a new calendar integration, with provider-specific parsing and optional pre-validation.
  """
  @spec create_integration(%{String.t() => term()}, user_id()) ::
          {:ok, integration()} | {:error, Ecto.Changeset.t() | any()}
  def create_integration(params, user_id) when is_map(params) and is_integer(user_id) do
    with {:ok, attrs} <- Creation.prepare_attrs(params, user_id),
         {:ok, attrs} <- Creation.prevalidate_config(attrs) do
      CalendarManagement.create_calendar_integration(attrs)
    end
  end

  @doc "Updates an existing calendar integration."
  @spec update_integration(integration(), %{optional(atom()) => term()}) ::
          {:ok, integration()} | {:error, Ecto.Changeset.t()}
  def update_integration(integration, attrs) do
    CalendarManagement.update_calendar_integration(integration, attrs)
  end

  @doc """
  Toggles active status of an integration by ID for a user.
  Ensures primary reassignment is handled atomically.
  """
  @spec toggle_integration(integration_id(), user_id()) :: {:ok, integration()} | {:error, any()}
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
  @spec set_primary(user_id(), integration_id()) :: {:ok, integration()} | {:error, any()}
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
  @spec discover_calendars_for_integration(integration()) :: {:ok, list()} | {:error, any()}
  def discover_calendars_for_integration(integration) do
    Discovery.discover_calendars_for_integration(integration)
  end

  @doc """
  Updates the calendar selection for an integration, optionally setting explicit default.
  """
  @spec update_calendar_selection(integration(), %{String.t() => term()}) ::
          {:ok, integration()} | {:error, any()}
  def update_calendar_selection(integration, params) do
    Selection.update_calendar_selection(integration, params)
  end

  @doc """
  Toggles a single calendar's selection state within an integration.
  """
  @spec toggle_calendar_selection(integration(), String.t() | integer()) ::
          {:ok, integration()} | {:error, any()}
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
  @spec validate_connection(integration(), user_id()) :: {:ok, integration()} | {:error, any()}
  def validate_connection(integration, user_id) do
    Connection.validate_connection(integration, user_id)
  end

  # ---------------------------
  # Public API: Provider facade (for developer tooling and diagnostics)
  # ---------------------------

  @doc """
  Creates an event on the integration's calendar provider.

  Returns `{:ok, event_id}` where `event_id` is a string identifier, or
  `{:error, reason}`.
  """
  @spec create_provider_event(integration(), map()) :: {:ok, any()} | {:error, any()}
  def create_provider_event(%CalendarIntegrationSchema{} = integration, event_attrs) do
    with {:ok, adapter_client} <- ProviderAdapter.new_client_from_integration(integration) do
      adapter_client.provider_module.create_event(
        adapter_client.client,
        normalise_event_attrs(event_attrs)
      )
    end
  end

  @doc """
  Diagnostic-only: PUTs a pre-built iCalendar payload into a CalDAV-family
  integration's primary calendar, bypassing `ICalBuilder`.

  Used by `mix calendar_audit` to exercise adversarial server-generated
  payloads (e.g. Zimbra-style `TZID="Europe/Brussels"`) that Tymeslot's own
  writer never produces, so the audit can verify our parser handles them.
  Not intended for application use.
  """
  @spec put_raw_caldav_ical(integration(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, any()}
  def put_raw_caldav_ical(
        %CalendarIntegrationSchema{provider: provider} = integration,
        uid,
        ical_content
      ) do
    with {:ok, provider_atom} <- ProviderConfig.validate_provider(provider),
         {:caldav?, true} <- {:caldav?, ProviderConfig.caldav_based?(provider_atom)},
         {:ok, adapter_client} <- ProviderAdapter.new_client_from_integration(integration) do
      CaldavCommon.put_raw_event(adapter_client.client, uid, ical_content)
    else
      {:caldav?, false} -> {:error, :unsupported_provider}
      other -> other
    end
  end

  @doc """
  Fetches raw events from the provider and normalises them into `CalendarEvent` structs.

  Returns `{:ok, [CalendarEvent.t()]}` or `{:error, reason}`.
  """
  @spec fetch_and_normalise_provider_events(integration(), DateTime.t(), DateTime.t()) ::
          {:ok, list()} | {:error, any()}
  def fetch_and_normalise_provider_events(
        %CalendarIntegrationSchema{} = integration,
        range_start,
        range_end
      ) do
    with {:ok, adapter_client} <- ProviderAdapter.new_client_from_integration(integration) do
      context = %{
        calendar_integration_id: integration.id,
        provider_calendar_id: integration.default_booking_calendar_id || "",
        synced_at: DateTime.utc_now(:microsecond)
      }

      opts = [start_time: range_start, end_time: range_end]

      with {:ok, raw_events} <-
             adapter_client.provider_module.list_events(adapter_client.client, opts) do
        adapter_client.provider_module.normalise_events(raw_events, context)
      end
    end
  end

  @doc """
  Fetches events via the fresh-fetch path — the same code path the availability
  calculator uses at runtime. Returns plain maps (not `CalendarEvent` structs).

  This is the counterpart to `fetch_and_normalise_provider_events/3`, which goes
  through the sync/normalisation pipeline. Comparing results between the two
  paths catches divergence bugs (e.g. one expands recurring events, the other
  does not).
  """
  @spec fetch_fresh_events(integration(), DateTime.t(), DateTime.t()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_fresh_events(%CalendarIntegrationSchema{} = integration, range_start, range_end) do
    clients = ClientManager.clients_for_integration(integration)

    results =
      Enum.map(clients, fn client ->
        EventsRead.fetch_events_with_fallback(client, range_start, range_end)
      end)

    successes = for {:ok, events, _path} <- results, event <- events, do: event
    success_count = Enum.count(results, &match?({:ok, _events, _path}, &1))

    if success_count == 0 and results != [] do
      {:error, :all_clients_failed}
    else
      {:ok, Enum.uniq_by(successes, &{&1[:uid], &1[:start_time]})}
    end
  end

  @doc """
  Updates an event on the integration's calendar provider.

  Returns `:ok`, `{:ok, result}`, or `{:error, reason}`.
  """
  @spec update_provider_event(integration(), String.t(), map()) ::
          :ok | {:ok, any()} | {:error, any()}
  def update_provider_event(%CalendarIntegrationSchema{} = integration, event_id, event_attrs) do
    with {:ok, adapter_client} <- ProviderAdapter.new_client_from_integration(integration) do
      adapter_client.provider_module.update_event(
        adapter_client.client,
        event_id,
        normalise_event_attrs(event_attrs)
      )
    end
  end

  # Normalizes outbound event attrs for provider dispatch. Currently handles
  # the all-day `end_date == start_date` case: iCal, Google, and Outlook all
  # treat the end as exclusive for date-only events, so a single-day event
  # must have `end = start + 1`. Callers may pass `end = start` to express
  # "an event on that day"; this helper bridges the intent to the wire format.
  defp normalise_event_attrs(
         %{start_time: %Date{} = start_date, end_time: %Date{} = end_date} = attrs
       ) do
    if Date.compare(start_date, end_date) == :eq do
      %{attrs | end_time: Date.add(end_date, 1)}
    else
      attrs
    end
  end

  defp normalise_event_attrs(attrs), do: attrs

  @doc """
  Deletes an event from the integration's calendar provider.

  Returns `:ok`, `{:ok, result}`, or `{:error, reason}`.
  """
  @spec delete_provider_event(integration(), String.t()) ::
          :ok | {:ok, any()} | {:error, any()}
  def delete_provider_event(%CalendarIntegrationSchema{} = integration, event_id) do
    with {:ok, adapter_client} <- ProviderAdapter.new_client_from_integration(integration) do
      adapter_client.provider_module.delete_event(adapter_client.client, event_id, [])
    end
  end

  @doc """
  Performs a quick connectivity probe against the integration's provider.

  Delegates to the provider's `check_connectivity/1` callback. CalDAV providers
  send a PROPFIND request with a short timeout to verify reachability and
  authentication. OAuth providers return immediately since token validity is
  checked lazily on the first real API call.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec check_provider_connectivity(integration()) :: :ok | {:error, any()}
  def check_provider_connectivity(%CalendarIntegrationSchema{} = integration) do
    with {:ok, adapter_client} <- ProviderAdapter.new_client_from_integration(integration),
         {:ok, _info} <- adapter_client.provider_module.check_connectivity(adapter_client.client) do
      :ok
    end
  end

  @doc """
  Tests the connection and returns display-friendly message.
  Delegates to Connection.test_connection/1 to centralize provider resolution.
  """
  @spec test_connection(integration()) :: {:ok, String.t()} | {:error, any()}
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

  @doc """
  Returns the list of CalDAV-based provider atoms.
  See `Tymeslot.Integrations.Calendar.ProviderConfig.caldav_based_providers/0`.
  """
  defdelegate caldav_based_providers(), to: ProviderConfig

  @doc """
  Returns the list of CalDAV-based provider strings, matching the `provider`
  column shape stored in the database.
  """
  defdelegate caldav_based_provider_strings(), to: ProviderConfig

  # ---------------------------
  # Public API: Higher-level wrappers (submodules)
  # ---------------------------

  @doc """
  Validates and creates an integration through the creation pipeline.
  """
  @spec create_integration_with_validation(user_id(), %{String.t() => term()}, keyword()) ::
          {:ok, integration()}
          | {:error,
             {:form_errors, %{String.t() => term()}} | {:changeset, Ecto.Changeset.t()} | any()}
  def create_integration_with_validation(user_id, params, opts \\ []) do
    Creation.create_with_validation(user_id, params, opts)
  end

  @doc """
  Prepare selection params from selected paths and discovered calendars.
  """
  @spec prepare_selection_params([String.t()], list()) ::
          %{required(String.t()) => [String.t()] | [%{String.t() => term()}]}
  def prepare_selection_params(selected_paths, discovered) do
    Selection.prepare_selected_params(selected_paths, discovered)
  end

  @doc """
  Discover calendars and merge with existing selection state for an integration.
  """
  @spec discover_calendars_with_selection(integration()) :: {:ok, list()} | {:error, any()}
  def discover_calendars_with_selection(integration) do
    Selection.discover_with_selection(integration)
  end

  @doc """
  Validate a connection with a timeout wrapper.
  """
  @spec validate_connection_with_timeout(integration(), user_id(), keyword()) ::
          {:ok, integration()} | {:error, any()}
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

  ## Options
    - `:return_to` — relative path to redirect to after the OAuth callback
  """
  @spec initiate_google_oauth(user_id(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def initiate_google_oauth(user_id, opts \\ []) when is_integer(user_id) do
    OAuth.initiate_google_oauth(user_id, opts)
  end

  @doc """
  Initiates Outlook Calendar OAuth flow and returns the authorization URL.

  ## Options
    - `:return_to` — relative path to redirect to after the OAuth callback
  """
  @spec initiate_outlook_oauth(user_id(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def initiate_outlook_oauth(user_id, opts \\ []) when is_integer(user_id) do
    OAuth.initiate_outlook_oauth(user_id, opts)
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

  @doc """
  Formats token expiry info into a human-readable string.
  """
  @spec format_token_expiry(integration()) :: String.t()
  def format_token_expiry(integration) do
    case TokenUtils.format_token_expiry(integration) do
      {_status, message} -> message
    end
  end

  @doc """
  Checks if a Google integration needs scope upgrade.
  """
  @spec needs_scope_upgrade?(integration()) :: boolean()
  def needs_scope_upgrade?(integration) do
    OAuth.needs_scope_upgrade?(integration)
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
  @spec update_integration_with_discovery(integration()) ::
          {:ok, integration()} | {:error, term()}
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
          {:ok, %{calendars: list(), discovery_credentials: Discovery.discovery_credentials()}}
          | {:error, String.t()}
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
    Directory.format_provider_name(:calendar, provider)
  end

  @doc """
  Helper to extract a friendly display name from a calendar.
  Handles the case where Radicale calendars may have UUIDs as names.
  """
  @spec extract_calendar_display_name(%{
          optional(String.t()) => term(),
          optional(atom()) => term()
        }) ::
          String.t()
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
          {:ok, %{calendars: list(), discovery_credentials: Discovery.discovery_credentials()}}
          | {:error, any()}
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

  @doc """
  Reconnect an existing CalDAV-family integration. Always returns
  `{:ok, :needs_calendar_selection, payload}` on success — the caller
  must show the discovered calendars (pre-ticking the integration's
  existing `calendar_paths`) and then call
  `Calendar.finalise_caldav_reconnect/3` with the user's selection.

  Arguments:
    * `user_id` — owning user id, used to scope the fetch.
    * `integration_id` — the integration to reconnect.
    * `params` — map with `"url"`, `"username"`, `"password"`.
  """
  @spec reconnect_caldav_integration(user_id(), integration_id(), map()) ::
          {:ok, :needs_calendar_selection, %{calendars: [map()], credentials: map()}}
          | {:error, :not_found}
          | {:error, :invalid_credentials}
          | {:error, {:changeset, Ecto.Changeset.t()}}
          | {:error, term()}
  def reconnect_caldav_integration(user_id, integration_id, params)
      when is_integer(user_id) and is_integer(integration_id) and is_map(params) do
    with {:ok, integration} <-
           CalendarManagement.get_calendar_integration(integration_id, user_id) do
      Reconnection.reconnect(integration, params)
    end
  end

  @doc """
  Finalise the `:account_change` branch by persisting the user's selected
  calendars alongside the new credentials. See `reconnect_caldav_integration/3`.
  """
  @spec finalise_caldav_reconnect(user_id(), integration_id(), %{
          required(:payload) => map(),
          required(:selected_paths) => [String.t()]
        }) ::
          {:ok, integration()}
          | {:error, :not_found}
          | {:error, :no_calendars_selected}
          | {:error, {:changeset, Ecto.Changeset.t()}}
  def finalise_caldav_reconnect(user_id, integration_id, %{
        payload: payload,
        selected_paths: paths
      })
      when is_integer(user_id) and is_integer(integration_id) do
    with {:ok, integration} <-
           CalendarManagement.get_calendar_integration(integration_id, user_id) do
      Reconnection.finalise_account_change(integration, payload, paths)
    end
  end
end
