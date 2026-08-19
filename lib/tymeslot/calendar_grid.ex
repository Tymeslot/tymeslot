defmodule Tymeslot.CalendarGrid do
  @moduledoc """
  Context module for the calendar grid view.

  Provides functions to fetch cached calendar events for a date range,
  trigger background syncs for active integrations, and assign stable
  display colours to integrations.
  """

  alias Tymeslot.CalendarGrid.BookingEvent
  alias Tymeslot.CalendarGrid.BookingEvents
  alias Tymeslot.Integrations.Calendar.Appearance
  alias Tymeslot.Integrations.Calendar.CalendarAppearanceSchema
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Integrations.Calendar.EventColour
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Reminder
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias Tymeslot.Workers.RefreshOutlookCalendarWorker
  alias Tymeslot.Workers.SyncCalDavCalendarWorker
  alias Tymeslot.Workers.SyncDebugCalendarWorker
  alias Tymeslot.Workers.SyncExchangeCalendarWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker
  alias Tymeslot.Workers.SyncIcsCalendarWorker

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
  @debug_stale_minutes 15
  # Subscriptions are swept every 30 minutes; the buffer is wider than the
  # CalDAV ones because the publisher's own regeneration schedule sits on top
  # of ours, so a feed being an hour old is normal rather than a symptom.
  @subscription_stale_minutes 75
  # Exchange is swept on the same 30-minute cadence as a subscription, and for
  # the same reason: no delta mechanism, so every run re-reads the whole
  # window twice over. The buffer is the sweep interval plus queue wait.
  @exchange_stale_minutes 45

  @doc """
  Returns all cached calendar events for the given integration IDs within a time range.

  Queries the event cache for events overlapping the [start_dt, end_dt] window.
  Accepts a `:limit` option (default: unbounded) — see
  `ProviderCalendarEventQueries.list_for_range/4`.

  Reminders are normalised to the canonical `%{method:, minutes_before:}` shape,
  so callers can read `minutes_before` regardless of how the row was stored.
  """
  @spec list_events_for_range([integer()], DateTime.t(), DateTime.t(), keyword()) ::
          [ProviderCalendarEventSchema.t()]
  def list_events_for_range(integration_ids, start_dt, end_dt, opts \\ []) do
    integration_ids
    |> ProviderCalendarEventQueries.list_for_range(start_dt, end_dt, opts)
    |> Enum.map(&normalise_event_reminders/1)
  end

  @doc """
  Returns the user's live bookings overlapping `[start_dt, end_dt)` projected
  into the grid's event shape, excluding bookings whose provider-synced copy
  is identified by `synced_event_ids`. See
  `Tymeslot.CalendarGrid.BookingEvents.list_for_range/4`.
  """
  @spec list_booking_events_for_range(pos_integer(), DateTime.t(), DateTime.t(), MapSet.t()) ::
          [BookingEvent.t()]
  defdelegate list_booking_events_for_range(
                user_id,
                start_dt,
                end_dt,
                synced_event_ids \\ MapSet.new()
              ),
              to: BookingEvents,
              as: :list_for_range

  # How far ahead the desktop-reminder feed looks. Wide enough to cover the
  # longest reminder lead time (a week) while keeping the payload bounded.
  @reminder_feed_window_days 8

  @doc """
  Returns the user's upcoming timed events that carry at least one reminder,
  within `[now, now + #{@reminder_feed_window_days}d)`, scoped to the given
  (already visibility-filtered) integration IDs.

  Reminders are normalised to the canonical `%{method:, minutes_before:}` shape,
  so callers can read `minutes_before` regardless of how the row was stored.
  """
  @spec list_upcoming_events_with_reminders([integer()], DateTime.t()) ::
          [ProviderCalendarEventSchema.t()]
  def list_upcoming_events_with_reminders(integration_ids, now) do
    window_end = DateTime.add(now, @reminder_feed_window_days, :day)

    integration_ids
    |> ProviderCalendarEventQueries.list_upcoming_timed(now, window_end)
    |> Enum.map(&normalise_event_reminders/1)
    |> Enum.reject(&(&1.reminders == []))
  end

  # The reminders column is nullable, so a row written without one loads as nil
  # rather than an empty list.
  defp normalise_event_reminders(%{reminders: nil} = event),
    do: %{event | reminders: []}

  defp normalise_event_reminders(event),
    do: %{event | reminders: Enum.map(event.reminders, &Reminder.normalise/1)}

  @doc """
  Searches the user's cached calendar events by a free-text term.

  Matches case-insensitively against event title, description, and location,
  scoped to the user's active integrations. Pass `:hidden_integration_ids` in
  `opts` to exclude calendars the user has toggled off; results are ordered by
  start time and capped at a sensible limit. A blank term returns `[]`.
  """
  @spec search_events(integer(), String.t(), keyword()) :: [ProviderCalendarEventSchema.t()]
  def search_events(user_id, term, opts \\ []) do
    ProviderCalendarEventQueries.search(user_id, term, opts)
  end

  @doc """
  Enqueues sync workers for all active integrations belonging to the user.

  Each integration is dispatched to the appropriate worker based on its provider:
  - `"google"` → `SyncGoogleCalendarWorker`
  - `"outlook"` → `RefreshOutlookCalendarWorker` (delta sync or bootstrap; the
    standard webhook-driven `SyncOutlookCalendarWorker` is per-event and can't
    service a manual refresh on its own)
  - `"debug"` → `SyncDebugCalendarWorker`
  - `"ics_url"` → `SyncIcsCalendarWorker`
  - `"exchange"` → `SyncExchangeCalendarWorker`
  - any provider returned by `ProviderConfig.caldav_based_providers/0` →
    `SyncCalDavCalendarWorker`

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
          {:ok, _job} -> {count + 1, skip, errs}
          {:error, reason} -> {count, skip, [{integration.id, reason} | errs]}
        end
      end)

    {:ok, %{enqueued: enqueued, skipped: skipped, errors: errors}}
  end

  @doc """
  Returns the display class each of the given integrations paints its events in.

  An integration whose owner has picked a colour resolves to that palette
  key's class. The rest fall back to a rotation: integrations are sorted by id
  first, so the same integration keeps the same colour regardless of the order
  they are passed in, and the rotation wraps at `EventColour.rotation_size/0`.

  A picked colour is deliberately *not* taken out of the rotation. Doing so
  would shuffle every other integration's colour the moment one was picked,
  which is the opposite of the stability the sort exists to provide; the cost
  is that a picked colour may coincide with a rotated one.

  Returns `%{integration_id => tailwind_class}`.
  """
  @spec integration_colour_classes([map()]) :: %{integer() => String.t()}
  def integration_colour_classes(integrations) do
    integrations
    |> Enum.sort_by(& &1.id)
    |> Enum.with_index()
    |> Map.new(fn {integration, index} ->
      {integration.id, colour_class(integration, index)}
    end)
  end

  @doc """
  Tailwind classes for the calendars the organiser has given a colour of their
  own, keyed by `{integration_id, provider_calendar_id}`.

  Only calendars with an explicit choice appear. Everything else is absent on
  purpose, so the caller falls through to the integration's colour and then the
  rotation, rather than this map having to restate either.
  """
  @spec calendar_colour_classes([CalendarAppearanceSchema.t()]) :: %{
          {integer(), String.t()} => String.t()
        }
  def calendar_colour_classes(appearances) do
    appearances
    |> Enum.filter(&Appearance.chosen?/1)
    |> Map.new(fn appearance ->
      {{appearance.calendar_integration_id, appearance.provider_calendar_id},
       EventColour.tailwind_class(appearance.colour)}
    end)
  end

  # A blank colour is treated as no colour, not as an unrecognised one: it can
  # only reach the column from outside the changeset (a restore, a hand-written
  # UPDATE), and rotating is a better answer there than painting it neutral.
  defp colour_class(%{colour: colour}, _index) when is_binary(colour) and colour != "",
    do: EventColour.tailwind_class(colour)

  defp colour_class(_integration, index),
    do: EventColour.rotation_class(rem(index, EventColour.rotation_size()) + 1)

  @doc """
  Returns integrations whose cached data is stale.

  An integration is stale when `last_external_sync_at` is nil or older than the
  provider-appropriate threshold:
  - Webhook providers (Google, Outlook): #{@webhook_stale_minutes} min
  - CalDAV Tier 1 (sync-token, syncs every 15 min): #{@caldav_tier_stale_minutes[1]} min
  - CalDAV Tier 2 (CTag, syncs every 30 min): #{@caldav_tier_stale_minutes[2]} min
  - CalDAV Tier 3 (full fetch, syncs every 60 min): #{@caldav_tier_stale_minutes[3]} min
  - Calendar subscriptions (full fetch, syncs every 30 min): #{@subscription_stale_minutes} min
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
  # build datetimes at second precision and don't always supply synced_at —
  # they're writing what they just committed, so "now" is the correct sync
  # timestamp. synced_at is upcast unconditionally so a caller-supplied
  # second-precision value does not fail Ecto's :utc_datetime_usec check.
  defp normalise_cache_attrs(attrs) do
    now = DateTime.utc_now(:microsecond)

    attrs
    |> Map.update(:start_at, nil, &to_usec/1)
    |> Map.update(:end_at, nil, &to_usec/1)
    |> Map.put_new(:synced_at, now)
    |> Map.update!(:synced_at, &to_usec/1)
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
  The clock format to render times in for the given organiser: their stored
  choice, or the preset `locale` implies when they have never set one.

  For callers that hold only a user id, such as email templates. Anything
  already holding the preferences struct should resolve it directly through
  `Tymeslot.Utils.DateTimeUtils.TimeFormat.resolve/2` instead of paying for
  another query.
  """
  @spec get_user_time_format(integer() | nil, String.t() | nil) :: String.t()
  def get_user_time_format(nil, locale), do: TimeFormat.for_locale(locale)

  def get_user_time_format(user_id, locale) do
    user_id
    |> CalendarPreferencesQueries.get_or_create()
    |> Map.get(:time_format)
    |> TimeFormat.resolve(locale)
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

  defp stale_threshold_minutes(%{provider: "debug"}), do: @debug_stale_minutes

  defp stale_threshold_minutes(%{provider: "ics_url"}), do: @subscription_stale_minutes

  defp stale_threshold_minutes(%{provider: "exchange"}), do: @exchange_stale_minutes

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

  defp enqueue_sync_worker(%{provider: "outlook"} = integration) do
    %{"calendar_integration_id" => integration.id}
    |> RefreshOutlookCalendarWorker.new()
    |> Oban.insert()
  end

  defp enqueue_sync_worker(%{provider: "debug"} = integration) do
    %{"calendar_integration_id" => integration.id}
    |> SyncDebugCalendarWorker.new()
    |> Oban.insert()
  end

  # A subscription refresh is always a full re-fetch of the feed; there is no
  # delta mode to force past.
  defp enqueue_sync_worker(%{provider: "ics_url"} = integration) do
    %{"calendar_integration_id" => integration.id}
    |> SyncIcsCalendarWorker.new()
    |> Oban.insert()
  end

  # EWS has no delta mode either: a refresh re-reads the whole window through
  # both of the provider's reads.
  defp enqueue_sync_worker(%{provider: "exchange"} = integration) do
    %{"calendar_integration_id" => integration.id}
    |> SyncExchangeCalendarWorker.new()
    |> Oban.insert()
  end

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
