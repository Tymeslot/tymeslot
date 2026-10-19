defmodule Tymeslot.Integrations.Calendar do
  @moduledoc """
  Integration management for calendar providers.

  Owns CRUD, primary selection, discovery, validation, OAuth helpers and the
  higher-level orchestration wrappers used by LiveViews and controllers.

  Related sibling modules — public surface of the calendar domain, not detail
  behind this facade. Each is a sanctioned entry point covered by Core's own
  tests, so a rename goes red here before it breaks a downstream build.

    * `Tymeslot.Integrations.Calendar.Diagnostics` — direct provider-event
      operations and ephemeral integration builders used by `mix calendar_audit`
      and other diagnostic tooling.
    * `Tymeslot.Integrations.Calendar.EventColour` — the palette: which colour
      keys exist and what each maps to per provider. A pure lookup table.
    * `Tymeslot.Integrations.Calendar.Recurrence.RRule` — RFC 5545 recurrence
      parsing. Also pure, and already called directly from the calendar grid.
    * `Tymeslot.Integrations.Calendar.DisplayHelpers` — user-facing string
      helpers (provider display names, calendar name extraction, error
      message normalisation).
    * `Tymeslot.Integrations.Calendar.Events` — calendar event operations
      (list/create/update/delete events) used by the booking pipeline.
    * `Tymeslot.Integrations.Calendar.Webhooks` — handling of provider push
      notifications: verification and the sync jobs they enqueue.
  """

  @behaviour Tymeslot.Security.EncryptedStorage

  alias Tymeslot.Integrations.Calendar.Blocking
  alias Tymeslot.Integrations.Calendar.BookingEligibility
  alias Tymeslot.Integrations.Calendar.CalDAV.OfflineQueue
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.ColourOverrideQueries
  alias Tymeslot.Integrations.Calendar.ColourResolver
  alias Tymeslot.Integrations.Calendar.ColourWriteBack
  alias Tymeslot.Integrations.Calendar.Connection
  alias Tymeslot.Integrations.Calendar.Creation
  alias Tymeslot.Integrations.Calendar.Defaults
  alias Tymeslot.Integrations.Calendar.Discovery
  alias Tymeslot.Integrations.Calendar.Exchange.Creation, as: ExchangeCreation
  alias Tymeslot.Integrations.Calendar.Exchange.FreeBusy
  alias Tymeslot.Integrations.Calendar.IntegrationCacheQueries
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.Nextcloud.Login, as: NextcloudLogin
  alias Tymeslot.Integrations.Calendar.OAuth
  alias Tymeslot.Integrations.Calendar.Orchestration.Workflows
  alias Tymeslot.Integrations.Calendar.OwnerActions
  alias Tymeslot.Integrations.Calendar.Primary
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Reconnection
  alias Tymeslot.Integrations.Calendar.Runtime.CalendarPathResolver
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Integrations.Calendar.Shared.ProviderCommon
  alias Tymeslot.Integrations.Shared.Providers.Directory
  alias Tymeslot.Meetings
  alias Tymeslot.Security.EncryptedString

  @type user_id :: pos_integer()
  @type integration_id :: pos_integer()
  @type integration :: CalendarIntegrationSchema.t()
  @type calendar_selection_params :: %{required(:selected_calendars) => [String.t()]}
  @type colour_target :: {:meeting, Ecto.UUID.t()} | {:external, integration_id(), String.t()}

  @typedoc """
  One block of busy time read from a provider's free/busy view. It carries no
  item identity, so a caller correlates blocks by time and never by uid.
  """
  @type busy_interval :: FreeBusy.interval()

  @impl Tymeslot.Security.EncryptedStorage
  def encrypted_storage,
    do:
      {CalendarIntegrationSchema.__schema__(:source),
       CalendarIntegrationSchema.encrypted_credential_fields() ++
         EncryptedString.columns(CalendarIntegrationSchema)}

  # ---------------------------
  # Public API: Listing/CRUD
  # ---------------------------

  @doc """
  Whether the user has an active calendar integration a booking can be
  written to (see `Tymeslot.Integrations.Calendar.BookingEligibility`).
  """
  @spec has_bookable_integration?(user_id()) :: boolean()
  def has_bookable_integration?(user_id) when is_integer(user_id),
    do:
      CalendarIntegrationQueries.active_exists_except?(
        user_id,
        BookingEligibility.unbookable_providers()
      )

  @doc """
  Lists calendar integrations for a user and annotates the primary one.
  """
  @spec list_integrations(user_id()) :: [integration()]
  def list_integrations(user_id) when is_integer(user_id) do
    integrations = Management.list_calendar_integrations(user_id)

    primary_id =
      case Primary.get_primary_calendar_integration(user_id) do
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
    Management.get_calendar_integration(id, user_id)
  end

  @doc """
  The user's active Nextcloud calendar integrations, by id and name, for
  another integration to copy its server and login from.
  """
  @spec nextcloud_logins(user_id()) :: [%{id: integration_id(), name: String.t()}]
  defdelegate nextcloud_logins(user_id), to: NextcloudLogin, as: :list

  @doc """
  The server root, login name and password of one of the user's active
  Nextcloud calendar integrations. The password must never reach a browser.
  """
  @spec nextcloud_login(integration_id(), user_id()) ::
          {:ok, NextcloudLogin.login()} | {:error, :not_found}
  defdelegate nextcloud_login(integration_id, user_id), to: NextcloudLogin, as: :fetch

  @doc "See `Tymeslot.Integrations.Calendar.Creation.create/2`."
  @spec create_integration(%{String.t() => term()}, user_id()) ::
          {:ok, integration()} | {:error, Ecto.Changeset.t() | any()}
  defdelegate create_integration(params, user_id), to: Creation, as: :create

  @doc "See `Tymeslot.Integrations.Calendar.OwnerActions.rename_integration/4`."
  @spec rename_integration(user_id(), integration_id(), term(), map()) ::
          {:ok, integration()} | {:error, term()}
  defdelegate rename_integration(user_id, integration_id, name, metadata), to: OwnerActions

  @doc "See `Tymeslot.Integrations.Calendar.OwnerActions.set_integration_colour/3`."
  @spec set_integration_colour(user_id(), integration_id(), String.t() | nil) ::
          {:ok, integration()} | {:error, term()}
  defdelegate set_integration_colour(user_id, integration_id, colour), to: OwnerActions

  @doc "See `Tymeslot.Integrations.Calendar.OwnerActions.toggle_integration/2`."
  @spec toggle_integration(user_id(), integration_id()) :: {:ok, integration()} | {:error, any()}
  defdelegate toggle_integration(user_id, integration_id), to: OwnerActions

  @doc """
  The changes of the user's CalDAV calendars the server kept refusing, which
  are no longer replayed, by integration id. See
  `Tymeslot.Integrations.Calendar.CalDAV.OfflineQueue.stuck_changes/1`.
  """
  @spec stuck_changes(user_id()) :: %{
          integration_id() => %{count: pos_integer(), last_error: String.t() | nil}
        }
  defdelegate stuck_changes(user_id), to: OfflineQueue

  @doc "Of `user_ids`, those with at least one active calendar integration."
  @spec user_ids_with_active_calendar([user_id()]) :: [user_id()]
  defdelegate user_ids_with_active_calendar(user_ids),
    to: CalendarIntegrationQueries,
    as: :user_ids_with_active

  @doc """
  Takes the integration cache lock's advisory step for every calendar the
  user has, as deleting the account must before it deletes the user row. Call
  it inside a transaction. See
  `Tymeslot.Integrations.Calendar.IntegrationCacheQueries`.
  """
  @spec lock_calendar_caches(user_id()) :: :ok
  defdelegate lock_calendar_caches(user_id),
    to: IntegrationCacheQueries,
    as: :lock_cache_class_for_user

  @doc "See `Tymeslot.Integrations.Calendar.OwnerActions.dismiss_removed_calendars/3`."
  @spec dismiss_removed_calendars(user_id(), integration_id(), [String.t()]) ::
          {:ok, boolean()} | {:error, any()}
  defdelegate dismiss_removed_calendars(user_id, integration_id, shown_ids), to: OwnerActions

  @doc "See `Tymeslot.Integrations.Calendar.OwnerActions.retry_stuck_changes/2`."
  @spec retry_stuck_changes(user_id(), integration_id()) ::
          {:ok, non_neg_integer()} | {:error, any()}
  defdelegate retry_stuck_changes(user_id, integration_id), to: OwnerActions

  @doc "See `Tymeslot.Integrations.Calendar.OwnerActions.set_all_events_busy/3`."
  @spec set_all_events_busy(user_id(), integration_id(), boolean()) ::
          {:ok, integration()} | {:error, OwnerActions.refusal() | term()}
  defdelegate set_all_events_busy(user_id, integration_id, busy?), to: OwnerActions

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

  @doc "See `Tymeslot.Integrations.Calendar.OwnerActions.set_calendar_state/4`."
  @spec set_calendar_state(user_id(), integration_id(), String.t(), Blocking.state()) ::
          {:ok, integration()} | {:error, term()}
  defdelegate set_calendar_state(user_id, integration_id, calendar_id, state), to: OwnerActions

  @doc "See `Tymeslot.Integrations.Calendar.OwnerActions.set_calendar_shown/4`."
  @spec set_calendar_shown(user_id(), integration_id(), String.t(), boolean()) ::
          {:ok, integration()} | {:error, term()}
  defdelegate set_calendar_shown(user_id, integration_id, calendar_id, shown?), to: OwnerActions

  @doc "See `Tymeslot.Integrations.Calendar.OwnerActions.set_calendar_blocking/4`."
  @spec set_calendar_blocking(user_id(), integration_id(), String.t(), boolean()) ::
          {:ok, integration()} | {:error, term()}
  defdelegate set_calendar_blocking(user_id, integration_id, calendar_id, blocks?),
    to: OwnerActions

  @doc "See `Tymeslot.Integrations.Calendar.Blocking.booking_calendar_ids_by_integration/2`."
  @spec booking_calendar_ids_by_integration(user_id(), [integration()]) ::
          %{integration_id() => [String.t()]}
  defdelegate booking_calendar_ids_by_integration(user_id, integrations), to: Blocking

  @doc """
  Returns the selected entries from an integration's `calendar_list` that
  are also writable — the calendars available as booking/sync targets. See
  `Tymeslot.Integrations.Calendar.Selection.writable_calendars/1`.
  """
  @spec writable_calendars([CalendarEntry.t()] | nil) :: [CalendarEntry.t()]
  defdelegate writable_calendars(calendar_list), to: Selection

  @doc "Keeps the integrations that can take a new event. See `Selection.writable_integrations/1`."
  @spec writable_integrations([map()]) :: [map()]
  defdelegate writable_integrations(integrations), to: Selection

  @doc """
  Drops cached events from calendars the user has deselected. See
  `Tymeslot.Integrations.Calendar.Selection.visible_events/2`.
  """
  @spec visible_events([map()], [map()]) :: [map()]
  defdelegate visible_events(events, integrations), to: Selection

  @doc """
  Derives, per integration id, a query-ready description of calendar
  selection for filtering cached events in SQL. See
  `Tymeslot.Integrations.Calendar.Selection.visibility_rules/1`.
  """
  @spec visibility_rules([map()]) :: %{integer() => Selection.visibility_rule()}
  defdelegate visibility_rules(integrations), to: Selection

  @doc """
  Returns whether the integration has calendars selected but none of them
  are writable — the booking-target picker has nothing to offer even
  though the user has enabled calendars for this account. Distinguishes
  that dead end from "nothing selected yet" (`Selection.selected_calendars/1`
  is empty), which is a different, unremarkable state.
  """
  @spec all_selected_read_only?([CalendarEntry.t()] | nil) :: boolean()
  def all_selected_read_only?(calendar_list) do
    Selection.selected_calendars(calendar_list) != [] and
      writable_calendars(calendar_list) == []
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
  Resolves the calendar entry bookings on this integration are written to,
  tagged `:ok` or `:read_only`, or `:none` when there is no such entry. Unlike
  `default_booking_calendar/2`, this follows the stored booking calendar even
  when it is read-only and never guesses "first calendar". See
  `Tymeslot.Integrations.Calendar.Defaults.booking_target/1`.
  """
  @spec booking_target(%{
          :calendar_list => [CalendarEntry.t()] | nil,
          :default_booking_calendar_id => String.t() | nil,
          optional(atom()) => term()
        }) :: {:ok, CalendarEntry.t()} | {:read_only, CalendarEntry.t()} | :none
  defdelegate booking_target(integration), to: Defaults

  @doc """
  Resolves the calendar entry an event was synced from. See
  `Tymeslot.Integrations.Calendar.Selection.calendar_for_event/2`.
  """
  @spec calendar_for_event(map(), [CalendarEntry.t()] | nil) :: CalendarEntry.t() | nil
  defdelegate calendar_for_event(event, calendar_list), to: Selection

  @doc """
  The collection path a CalDAV-family integration writes new events to, or
  `nil` when it has none. See
  `Tymeslot.Integrations.Calendar.Runtime.CalendarPathResolver.resolve/1`.
  """
  @spec booking_calendar_path(integration()) :: String.t() | nil
  defdelegate booking_calendar_path(integration), to: CalendarPathResolver, as: :resolve

  @doc """
  The collections of a CalDAV-family integration a write may be aimed at: its
  selected calendars that are not read-only. See
  `Tymeslot.Integrations.Calendar.Shared.ProviderCommon.caldav_writable_paths/1`.
  """
  @spec writable_calendar_paths(integration()) :: [String.t()]
  defdelegate writable_calendar_paths(integration),
    to: ProviderCommon,
    as: :caldav_writable_paths

  # ---------------------------
  # Public API: Validation/Connection
  # ---------------------------

  @doc """
  Tests connectivity to an integration's provider and returns a
  display-friendly message.

  `:scope` distinguishes an interactive "Test connection" click from a
  scheduled background probe; see
  `Tymeslot.Integrations.Calendar.Connection.test_connection/2`.
  """
  @spec test_connection(integration(), keyword()) :: {:ok, String.t()} | {:error, any()}
  defdelegate test_connection(integration, opts \\ []), to: Connection

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

  @doc """
  Returns `true` when the provider refuses every write, so its calendars can
  block availability but can never receive an event. Takes the provider atom
  or the string form stored on an integration.

  For the narrower question of whether a booking may be written to a given
  integration, see `Tymeslot.Integrations.Calendar.BookingEligibility`.
  """
  @spec read_only_provider?(atom() | String.t() | nil) :: boolean()
  defdelegate read_only_provider?(provider), to: ProviderConfig, as: :read_only?

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
  Validates and creates a read-only calendar subscription from a feed URL.
  """
  @spec create_subscription_with_validation(user_id(), %{String.t() => term()}, keyword()) ::
          {:ok, integration()}
          | {:error,
             {:form_errors, %{String.t() => term()}}
             | {:changeset, Ecto.Changeset.t()}
             | {:rate_limited, String.t()}
             | :unattributable}
  def create_subscription_with_validation(user_id, params, opts \\ []) do
    Creation.create_subscription_with_validation(user_id, params, opts)
  end

  @doc """
  Validates and creates a read-only Exchange (EWS) integration.
  """
  @spec create_exchange_with_validation(user_id(), %{String.t() => term()}, keyword()) ::
          {:ok, integration()}
          | {:error,
             {:form_errors, %{String.t() => term()}}
             | {:changeset, Ecto.Changeset.t()}
             | {:rate_limited, String.t()}
             | :unattributable
             | :duplicate_integration}
  def create_exchange_with_validation(user_id, params, opts) do
    ExchangeCreation.create_with_validation(user_id, params, opts)
  end

  @doc """
  Prepare selection params from selected paths and discovered calendars.
  """
  @spec prepare_selection_params([String.t()], list()) ::
          %{required(String.t()) => [String.t()] | [CalendarEntry.t()]}
  def prepare_selection_params(selected_paths, discovered) do
    Selection.prepare_selected_params(selected_paths, discovered)
  end

  @doc "See `Tymeslot.Integrations.Calendar.OwnerActions.delete_integration/2`."
  @spec delete_with_primary_reassignment_and_invalidate(user_id(), integration_id()) ::
          {:ok, any()} | {:error, any()}
  defdelegate delete_with_primary_reassignment_and_invalidate(user_id, integration_id),
    to: OwnerActions,
    as: :delete_integration

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
  Starts a Google or Outlook calendar OAuth flow and returns the
  authorisation URL. See `Tymeslot.Integrations.Calendar.OAuth.initiate/3`.
  """
  @spec initiate_oauth(OAuth.provider(), user_id(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  defdelegate initiate_oauth(provider, user_id, opts \\ []), to: OAuth, as: :initiate

  @doc """
  Completes a Google or Outlook OAuth callback and connects the calendar.
  """
  @spec complete_oauth(OAuth.provider(), String.t(), String.t(), pos_integer()) ::
          {:ok, integration()} | {:error, term()}
  defdelegate complete_oauth(provider, code, state, user_id), to: OAuth, as: :complete

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
  def list_available_providers(type) do
    Directory.list(type)
  end

  @doc "See `Tymeslot.Integrations.Calendar.OwnerActions.refresh_all_integrations/1`."
  @spec refresh_all_integrations(user_id()) ::
          {:ok, [{String.t(), :ok | {:error, term()}}]} | {:error, {:rate_limited, String.t()}}
  defdelegate refresh_all_integrations(user_id), to: OwnerActions

  @doc """
  Discovers calendars for raw credentials and filters them for valid paths.

  `user_id` is the plain owner id the discovery is charged to; the
  rate-limiter actor tuple is built internally rather than by the caller.
  """
  @spec discover_and_filter_calendars(
          atom() | String.t(),
          String.t(),
          String.t(),
          String.t(),
          user_id(),
          keyword()
        ) ::
          {:ok, %{calendars: list(), discovery_credentials: Discovery.discovery_credentials()}}
          | {:error, any()}
  def discover_and_filter_calendars(provider, url, username, password, user_id, opts \\ []) do
    Workflows.discover_and_filter_calendars(provider, url, username, password, user_id, opts)
  end

  # ---------------------------
  # Public API: Reconnection
  # ---------------------------

  @doc """
  Reconnect an existing CalDAV-family integration. Returns
  `{:ok, :needs_calendar_selection, payload}` (the caller must prompt for
  calendar selection and then call `finalise_caldav_reconnect/3`) or an error.
  See `Reconnection.reconnect_for_user/3`.
  """
  @spec reconnect_caldav_integration(user_id(), integration_id(), map()) ::
          Reconnection.reconnect_ok()
          | {:error, :not_found}
          | Reconnection.reconnect_error()
  defdelegate reconnect_caldav_integration(user_id, integration_id, params),
    to: Reconnection,
    as: :reconnect_for_user

  @doc """
  Finalise the account-change branch by persisting the user's selected
  calendars alongside the new credentials. See
  `reconnect_caldav_integration/3` and `Reconnection.finalise_for_user/3`.
  """
  @spec finalise_caldav_reconnect(user_id(), integration_id(), %{
          required(:payload) => map(),
          required(:selected_paths) => [String.t()]
        }) ::
          {:ok, integration()}
          | {:error, :not_found}
          | {:error, :no_calendars_selected}
          | {:error, {:changeset, Ecto.Changeset.t()}}
  defdelegate finalise_caldav_reconnect(user_id, integration_id, selection),
    to: Reconnection,
    as: :finalise_for_user

  # ---------------------------
  # Public API: Event colour
  # ---------------------------

  @doc """
  Sets a durable per-event colour override for `user_id` on `target`, then
  (for external events) best-effort writes it back to the provider. Returns the
  persisted override.
  """
  @spec set_event_colour(user_id(), colour_target(), String.t()) ::
          {:ok, term()} | {:error, :not_found | Ecto.Changeset.t()}
  def set_event_colour(user_id, target, colour) do
    with :ok <- verify_colour_target(user_id, target) do
      put_event_colour(user_id, target, colour)
    end
  end

  defp put_event_colour(user_id, {:meeting, meeting_id}, colour),
    do: ColourOverrideQueries.set_meeting(user_id, meeting_id, colour)

  defp put_event_colour(user_id, {:external, integration_id, uid}, colour) do
    with {:ok, override} <-
           ColourOverrideQueries.set_external(user_id, integration_id, uid, colour) do
      ColourWriteBack.enqueue(user_id, integration_id, uid, colour)
      {:ok, override}
    end
  end

  @doc """
  Clears a per-event colour override for `user_id` on `target`. For external
  events the host calendar is left untouched; the next sync reconciles.
  """
  @spec clear_event_colour(user_id(), colour_target()) :: :ok | {:error, :not_found}
  def clear_event_colour(user_id, target) do
    with :ok <- verify_colour_target(user_id, target) do
      remove_event_colour(user_id, target)
    end
  end

  defp remove_event_colour(user_id, {:meeting, meeting_id}),
    do: ColourOverrideQueries.clear_meeting(user_id, meeting_id)

  # Clearing drops the override only; the host calendar is left untouched and
  # the next sync reconciles — so no write-back is enqueued here.
  defp remove_event_colour(user_id, {:external, integration_id, uid}),
    do: ColourOverrideQueries.clear_external(user_id, integration_id, uid)

  # The target arrives from the browser, so the meeting or integration it
  # names must be the user's own; one that is not is not found.
  defp verify_colour_target(user_id, {:meeting, meeting_id}) do
    with {:ok, _meeting} <- Meetings.get_meeting_for_organizer(meeting_id, user_id), do: :ok
  end

  defp verify_colour_target(user_id, {:external, integration_id, _uid}) do
    if CalendarIntegrationQueries.owned_by?(integration_id, user_id),
      do: :ok,
      else: {:error, :not_found}
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
end
