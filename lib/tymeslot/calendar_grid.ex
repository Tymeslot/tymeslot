defmodule Tymeslot.CalendarGrid do
  @moduledoc """
  Context module for the calendar grid view.

  Provides functions to fetch cached calendar events for a date range,
  trigger background syncs for active integrations, and assign stable
  color indices to integrations.
  """

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Workers.SyncCalDavCalendarWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  @palette_size 8

  @caldav_providers Enum.map(ProviderConfig.caldav_based_providers(), &Atom.to_string/1)

  # Staleness thresholds (minutes). Each threshold is the sync interval
  # plus a buffer for queue wait, network latency, and retries.
  @webhook_stale_minutes 30
  @caldav_tier_stale_minutes %{
    1 => 25,
    2 => 45,
    3 => 90
  }
  @caldav_default_stale_minutes 25

  @doc """
  Returns all cached calendar events for the given integration IDs within a time range.

  Queries the event cache for events overlapping the [start_dt, end_dt] window.
  """
  @spec list_events_for_range([integer()], DateTime.t(), DateTime.t()) ::
          [ProviderCalendarEventSchema.t()]
  def list_events_for_range(integration_ids, start_dt, end_dt) do
    ProviderCalendarEventQueries.list_for_range(integration_ids, start_dt, end_dt)
  end

  @doc """
  Enqueues sync workers for all active integrations belonging to the user.

  Each integration is dispatched to the appropriate worker based on its provider:
  - `"google"` → `SyncGoogleCalendarWorker`
  - `"outlook"` → skipped (event-driven via Microsoft Graph webhooks)
  - `"caldav"` / `"radicale"` / `"nextcloud"` / `"zimbra"` → `SyncCalDavCalendarWorker`

  Returns `{:ok, %{enqueued: count, errors: [{integration_id, reason}]}}`.
  """
  @spec refresh_events(integer()) ::
          {:ok,
           %{
             enqueued: non_neg_integer(),
             skipped: non_neg_integer(),
             errors: [{integer(), term()}]
           }}
  def refresh_events(user_id) do
    # list_active_for_user decrypts credentials; acceptable overhead for a
    # user-initiated refresh since we need id + provider for each integration.
    integrations = CalendarIntegrationQueries.list_active_for_user(user_id)

    {enqueued, skipped, errors} =
      Enum.reduce(integrations, {0, 0, []}, fn integration, {count, skip, errs} ->
        case enqueue_sync_worker(integration) do
          # Outlook is webhook-driven; enqueue_sync_worker returns {:ok, nil}.
          # No Oban job fires, so no broadcast_sync_complete will arrive.
          # Tracked separately so the UI can pre-count these as done.
          {:ok, nil} -> {count, skip + 1, errs}
          {:ok, _job} -> {count + 1, skip, errs}
          {:error, reason} -> {count, skip, [{integration.id, reason} | errs]}
        end
      end)

    {:ok, %{enqueued: enqueued, skipped: skipped, errors: errors}}
  end

  @doc """
  Returns a stable color-index map for the given integrations.

  Integrations are sorted by id before assignment so that the same
  integration always receives the same index (1..#{@palette_size}),
  regardless of the order they are passed in. Indices rotate through
  the palette size. The web layer maps these to CSS classes.

  Returns `%{integration_id => 1..#{@palette_size}}`.
  """
  @spec get_integration_color_indices([map()]) :: %{integer() => pos_integer()}
  def get_integration_color_indices(integrations) do
    integrations
    |> Enum.sort_by(& &1.id)
    |> Enum.with_index()
    |> Map.new(fn {integration, index} ->
      {integration.id, rem(index, @palette_size) + 1}
    end)
  end

  @doc """
  Returns integrations whose cached data is stale.

  An integration is stale when `last_external_sync_at` is nil or older than the
  provider-appropriate threshold:
  - Webhook providers (Google, Outlook): #{@webhook_stale_minutes} min
  - CalDAV Tier 1 (sync-token, syncs every 15 min): #{@caldav_tier_stale_minutes[1]} min
  - CalDAV Tier 2 (CTag, syncs every 30 min): #{@caldav_tier_stale_minutes[2]} min
  - CalDAV Tier 3 (full fetch, syncs every 60 min): #{@caldav_tier_stale_minutes[3]} min
  """
  @spec stale_integrations([CalendarIntegrationSchema.t()]) :: [CalendarIntegrationSchema.t()]
  def stale_integrations(integrations) do
    now = DateTime.utc_now()
    Enum.filter(integrations, &stale?(&1, now))
  end

  @doc """
  Returns the oldest `last_external_sync_at` across the given integrations,
  or nil when none have synced.
  """
  @spec oldest_sync_at([CalendarIntegrationSchema.t()]) :: DateTime.t() | nil
  def oldest_sync_at([]), do: nil

  def oldest_sync_at(integrations) do
    timestamps =
      integrations
      |> Enum.map(& &1.last_external_sync_at)
      |> Enum.reject(&is_nil/1)

    if timestamps == [], do: nil, else: Enum.min(timestamps, DateTime)
  end

  @doc """
  Inserts a newly created event into the local cache so it appears
  immediately without waiting for the next sync cycle.

  Accepts a map with `:uid`, `:calendar_integration_id`, `:title`,
  `:start_at`, `:end_at`, and optionally `:all_day`.
  """
  @spec cache_created_event(map()) :: :ok
  def cache_created_event(attrs) do
    {:ok, _count} = ProviderCalendarEventQueries.upsert_batch([normalise_cache_attrs(attrs)])
    :ok
  end

  @doc """
  Updates a cached event's attributes via upsert.

  Accepts a map with at least `:uid` and `:calendar_integration_id`.
  """
  @spec update_cached_event(map()) :: :ok
  def update_cached_event(attrs) do
    {:ok, _count} = ProviderCalendarEventQueries.upsert_batch([normalise_cache_attrs(attrs)])
    :ok
  end

  # The cached events schema stores start/end/synced_at as :utc_datetime_usec
  # and requires synced_at NOT NULL. Dashboard-originated create/update flows
  # build datetimes at second precision and don't supply synced_at — they're
  # writing what they just committed, so "now" is the correct sync timestamp.
  defp normalise_cache_attrs(attrs) do
    now = DateTime.utc_now(:microsecond)

    attrs
    |> Map.update(:start_at, nil, &to_usec/1)
    |> Map.update(:end_at, nil, &to_usec/1)
    |> Map.put_new(:synced_at, now)
  end

  defp to_usec(%DateTime{microsecond: {_value, 6}} = dt), do: dt
  defp to_usec(%DateTime{} = dt), do: %{dt | microsecond: {elem(dt.microsecond, 0), 6}}
  defp to_usec(other), do: other

  @doc "Fetches a single cached event by integration ID and UID."
  @spec get_cached_event(integer(), String.t()) ::
          {:ok, CalendarEvent.t()} | {:error, :not_found}
  def get_cached_event(integration_id, uid) do
    case ProviderCalendarEventQueries.get_by_uid(integration_id, uid) do
      {:ok, record} -> {:ok, ProviderCalendarEventSchema.to_calendar_event(record)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Removes a cached event by its integration ID and UID.
  """
  @spec delete_cached_event(integer(), String.t()) :: {:ok, :deleted | :not_found}
  def delete_cached_event(integration_id, uid) do
    ProviderCalendarEventQueries.delete_by_uid(integration_id, uid)
  end

  @doc """
  Returns active calendar integrations for the given user.
  """
  @spec list_active_integrations(integer()) :: [CalendarIntegrationSchema.t()]
  def list_active_integrations(user_id) do
    CalendarIntegrationQueries.list_active_for_user(user_id)
  end

  @doc """
  Returns calendar preferences for the given user, or a default struct if none exist.
  """
  @spec get_or_create_preferences(integer()) :: term()
  def get_or_create_preferences(user_id) do
    CalendarPreferencesQueries.get_or_create(user_id)
  end

  @doc """
  Upserts calendar preferences for the given user.
  """
  @spec save_preferences(integer(), map()) :: {:ok, term()} | {:error, Ecto.Changeset.t()}
  def save_preferences(user_id, attrs) do
    CalendarPreferencesQueries.upsert(user_id, attrs)
  end

  # Private

  # Outlook pending initial setup: subscription registration hasn't succeeded yet
  # (e.g. WEBHOOK_BASE_URL not configured). This is "pending", not "stale" —
  # showing a stale banner the user can't resolve is just noise.
  defp stale?(%{provider: "outlook", graph_delta_link: nil, last_external_sync_at: nil}, _now),
    do: false

  defp stale?(%{last_external_sync_at: nil}, _now), do: true

  defp stale?(integration, now) do
    threshold = stale_threshold_minutes(integration)
    cutoff = DateTime.add(now, -threshold, :minute)
    DateTime.before?(integration.last_external_sync_at, cutoff)
  end

  defp stale_threshold_minutes(%{provider: provider, caldav_sync_tier: tier})
       when provider in @caldav_providers do
    Map.get(@caldav_tier_stale_minutes, tier, @caldav_default_stale_minutes)
  end

  defp stale_threshold_minutes(_integration), do: @webhook_stale_minutes

  defp enqueue_sync_worker(%{provider: "google"} = integration) do
    %{"calendar_integration_id" => integration.id}
    |> SyncGoogleCalendarWorker.new()
    |> Oban.insert()
  end

  # Outlook syncs are event-driven via Microsoft Graph webhooks; no full-sync worker exists.
  defp enqueue_sync_worker(%{provider: "outlook"} = _integration), do: {:ok, nil}

  defp enqueue_sync_worker(%{provider: provider} = integration) do
    if provider in @caldav_providers do
      # Manual refresh always forces a full fetch: users click Refresh because
      # they believe something is missing, and delta sync is exactly what would
      # miss it. See docs/superpowers/specs/2026-04-13-caldav-periodic-full-resync-design.md.
      %{
        "calendar_integration_id" => integration.id,
        "force_full_fetch" => true
      }
      |> SyncCalDavCalendarWorker.new()
      |> Oban.insert()
    else
      {:error, "unknown provider: #{provider} for integration #{integration.id}"}
    end
  end
end
