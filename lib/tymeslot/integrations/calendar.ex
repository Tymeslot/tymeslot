defmodule Tymeslot.Integrations.Calendar do
  @moduledoc """
  Integration management for calendar providers.

  Owns CRUD, primary selection, discovery, validation, OAuth helpers,
  and the higher-level orchestration wrappers used by LiveViews and
  controllers.

  Related sibling modules:

    * `Tymeslot.Integrations.Calendar.Diagnostics` — direct provider-event
      operations and ephemeral integration builders used by `mix calendar_audit`
      and other diagnostic tooling.
    * `Tymeslot.Integrations.Calendar.DisplayHelpers` — user-facing string
      helpers (provider display names, calendar name extraction, error
      message normalisation).
    * `Tymeslot.Integrations.Calendar.Events` — calendar event operations
      (list/create/update/delete events) used by the booking pipeline.
    * `Tymeslot.Integrations.Calendar.Webhooks` — webhook lookup and
      notification tracking.
  """

  @behaviour Tymeslot.Security.EncryptedStorage

  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.ColourOverrideQueries
  alias Tymeslot.Integrations.Calendar.ColourResolver
  alias Tymeslot.Integrations.Calendar.Connection
  alias Tymeslot.Integrations.Calendar.Creation
  alias Tymeslot.Integrations.Calendar.Defaults
  alias Tymeslot.Integrations.Calendar.Deletion
  alias Tymeslot.Integrations.Calendar.Discovery
  alias Tymeslot.Integrations.Calendar.OAuth
  alias Tymeslot.Integrations.Calendar.Orchestration.Workflows
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Reconnection
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Integrations.Calendar.TokenUtils
  alias Tymeslot.Integrations.{CalendarManagement, CalendarPrimary}
  alias Tymeslot.Integrations.Providers.Directory
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Workers.ColourWriteBackWorker

  require Logger

  @type user_id :: pos_integer()
  @type integration_id :: pos_integer()
  @type integration :: CalendarIntegrationSchema.t()
  @type calendar_selection_params :: %{required(:selected_calendars) => [String.t()]}
  @type colour_target :: {:meeting, Ecto.UUID.t()} | {:external, integration_id(), String.t()}

  @impl Tymeslot.Security.EncryptedStorage
  def encrypted_storage,
    do:
      {CalendarIntegrationSchema.__schema__(:source),
       CalendarIntegrationSchema.encrypted_credential_fields()}

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
        is_now_selected =
          if to_string(cal.id) == to_string(calendar_id), do: !cal.selected, else: cal.selected

        if is_now_selected, do: [to_string(cal.id) | acc], else: acc
      end)

    update_calendar_selection(integration, %{"selected_calendars" => current_selection})
  end

  @doc """
  Returns the entries from an integration's `calendar_list` whose `selected`
  flag is truthy, including read-only ones. See
  `Tymeslot.Integrations.Calendar.Selection.selected_calendars/1`.

  Use this for conflict-checking visibility — a calendar the user cannot
  write to can still surface existing events. Callers that need a booking or
  sync target (which must be writable) should use `writable_calendars/1`
  instead.
  """
  @spec selected_calendars([CalendarEntry.t()] | nil) :: [CalendarEntry.t()]
  defdelegate selected_calendars(calendar_list), to: Selection

  @doc """
  Returns the selected entries from an integration's `calendar_list` that
  are also writable — the calendars available as booking/sync targets. See
  `Tymeslot.Integrations.Calendar.Selection.writable_calendars/1`.
  """
  @spec writable_calendars([CalendarEntry.t()] | nil) :: [CalendarEntry.t()]
  defdelegate writable_calendars(calendar_list), to: Selection

  @doc """
  Returns whether the integration has calendars selected but none of them
  are writable — the booking-target picker has nothing to offer even
  though the user has enabled calendars for this account. Distinguishes
  that dead end from "nothing selected yet" (`selected_calendars/1` is
  empty), which is a different, unremarkable state.
  """
  @spec all_selected_read_only?([CalendarEntry.t()] | nil) :: boolean()
  def all_selected_read_only?(calendar_list) do
    selected_calendars(calendar_list) != [] and writable_calendars(calendar_list) == []
  end

  @doc """
  Resolves the calendar entry that booking currently targets within a
  calendar list. See
  `Tymeslot.Integrations.Calendar.Defaults.default_booking_calendar/2`.
  """
  @spec default_booking_calendar([CalendarEntry.t()] | nil, String.t() | nil) ::
          CalendarEntry.t() | nil
  defdelegate default_booking_calendar(calendar_list, booking_id), to: Defaults

  @doc """
  Resolves the calendar entry that booking is *confirmed* to target: the
  entry matching `default_booking_calendar_id`, else the provider-primary
  entry. Unlike `default_booking_calendar/2`, this never guesses "first
  calendar" — it returns `nil` until a target has actually been chosen. See
  `Tymeslot.Integrations.Calendar.Defaults.confirmed_booking_calendar/1`.
  """
  @spec confirmed_booking_calendar(%{
          :calendar_list => [CalendarEntry.t()] | nil,
          :default_booking_calendar_id => String.t() | nil,
          optional(atom()) => term()
        }) :: CalendarEntry.t() | nil
  defdelegate confirmed_booking_calendar(integration), to: Defaults

  @doc """
  Finds the calendar entry with the given id. See
  `Tymeslot.Integrations.Calendar.Selection.find_calendar_by_id/2`.
  """
  @spec find_calendar_by_id([CalendarEntry.t()], String.t() | nil) :: CalendarEntry.t() | nil
  defdelegate find_calendar_by_id(calendar_list, id), to: Selection

  @doc """
  Finds the calendar entry whose `path` is a prefix of the given
  provider-side identifier. See
  `Tymeslot.Integrations.Calendar.Selection.find_calendar_by_path/2`.
  """
  @spec find_calendar_by_path([CalendarEntry.t()], String.t() | nil) :: CalendarEntry.t() | nil
  defdelegate find_calendar_by_path(calendar_list, path), to: Selection

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
          %{required(String.t()) => [String.t()] | [CalendarEntry.t()]}
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
  # Public API: Orchestration helpers
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
  Discovers calendars for raw credentials and filters them for valid paths.
  """
  @spec discover_and_filter_calendars(atom() | String.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{calendars: list(), discovery_credentials: Discovery.discovery_credentials()}}
          | {:error, any()}
  def discover_and_filter_calendars(provider, url, username, password) do
    Workflows.discover_and_filter_calendars(provider, url, username, password)
  end

  # ---------------------------
  # Public API: Reconnection
  # ---------------------------

  @doc """
  Reconnect an existing CalDAV-family integration. Returns either
  `{:ok, :updated, integration}` (password-only path, done) or
  `{:ok, :needs_calendar_selection, payload}` (account change; caller must
  prompt for calendar selection and then call
  `Calendar.finalise_caldav_reconnect/3`).

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

  # ---------------------------
  # Public API: Event colour
  # ---------------------------

  @doc """
  Sets a durable per-event colour override for `user_id` on `target`, then
  (for external events) best-effort writes it back to the provider. Returns the
  persisted override.
  """
  @spec set_event_colour(user_id(), colour_target(), String.t()) ::
          {:ok, term()} | {:error, Ecto.Changeset.t()}
  def set_event_colour(user_id, {:meeting, meeting_id}, colour),
    do: ColourOverrideQueries.set_meeting(user_id, meeting_id, colour)

  def set_event_colour(user_id, {:external, integration_id, uid}, colour) do
    with {:ok, override} <-
           ColourOverrideQueries.set_external(user_id, integration_id, uid, colour) do
      maybe_enqueue_colour_write_back(user_id, integration_id, uid, colour)
      {:ok, override}
    end
  end

  @doc """
  Clears a per-event colour override for `user_id` on `target`. For external
  events the host calendar is left untouched; the next sync reconciles.
  """
  @spec clear_event_colour(user_id(), colour_target()) :: :ok
  def clear_event_colour(user_id, {:meeting, meeting_id}),
    do: ColourOverrideQueries.clear_meeting(user_id, meeting_id)

  def clear_event_colour(user_id, {:external, integration_id, uid}) do
    # Clearing drops the override only; the host calendar is left untouched and
    # the next sync reconciles — so no write-back is enqueued here.
    ColourOverrideQueries.clear_external(user_id, integration_id, uid)
  end

  @doc """
  Returns a user's colour overrides as a lookup map keyed for the resolver:
  `{:meeting, id}` / `{:external, integration_id, uid}` => palette key.
  """
  @spec overrides_for(user_id()) :: %{optional(tuple()) => String.t()}
  def overrides_for(user_id), do: ColourOverrideQueries.for_user(user_id)

  @doc """
  Resolves the palette key to display for an event: the user's durable
  override wins, else the provider-synced colour, else `nil` (caller applies
  its own source/integration default).
  """
  @spec resolve_event_colour(override :: String.t() | nil, provider_colour :: String.t() | nil) ::
          String.t() | nil
  def resolve_event_colour(override, provider_colour),
    do: ColourResolver.resolve(override, provider_colour)

  # Best-effort provider write-back for a *set*. The worker patches only the
  # provider's colour field; Outlook and read-only calendars are handled
  # inside the worker. `replace: [:args]` ensures that when a user changes the
  # colour again before the previous job has run, the pending job's args are
  # replaced in place to carry the newest colour — without it, `unique` alone
  # would keep the *older* job (and its stale colour) and silently drop the
  # newer enqueue.
  defp maybe_enqueue_colour_write_back(user_id, integration_id, uid, colour) do
    %{"user_id" => user_id, "integration_id" => integration_id, "uid" => uid, "colour" => colour}
    |> ColourWriteBackWorker.new(replace: [:args])
    |> Oban.insert()
    |> log_colour_write_back_enqueue_error(user_id, integration_id)

    :ok
  end

  defp log_colour_write_back_enqueue_error({:ok, _job}, _user_id, _integration_id), do: :ok

  defp log_colour_write_back_enqueue_error({:error, reason}, user_id, integration_id) do
    Logger.warning("Failed to enqueue colour write-back",
      user_id: user_id,
      integration_id: integration_id,
      reason: inspect(reason)
    )
  end
end
