defmodule Tymeslot.CalendarGrid do
  @moduledoc """
  Context module for the calendar grid view.

  Provides functions to fetch cached calendar events for a date range,
  trigger background syncs for active integrations, and assign stable
  display colours to integrations.
  """

  alias Tymeslot.CalendarGrid.BookingEvent
  alias Tymeslot.CalendarGrid.BookingEvents
  alias Tymeslot.CalendarGrid.EventDeletion
  alias Tymeslot.CalendarGrid.EventEdit
  alias Tymeslot.CalendarGrid.EventMove
  alias Tymeslot.CalendarGrid.EventVideo
  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.CalendarGrid.EventVideoRoomSchema
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.Appearance
  alias Tymeslot.Integrations.Calendar.CalendarAppearanceSchema
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.EventColour
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Reminder
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.Video.ProviderConfig, as: VideoProviderConfig
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias Tymeslot.Workers.RefreshOutlookCalendarWorker
  alias Tymeslot.Workers.SyncCalDavCalendarWorker
  alias Tymeslot.Workers.SyncDebugCalendarWorker
  alias Tymeslot.Workers.SyncExchangeCalendarWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker
  alias Tymeslot.Workers.SyncIcsCalendarWorker

  @caldav_providers ProviderConfig.caldav_based_provider_strings()

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
  is among `cached_events`. See
  `Tymeslot.CalendarGrid.BookingEvents.list_for_range/4`.
  """
  @spec list_booking_events_for_range(
          pos_integer(),
          DateTime.t(),
          DateTime.t(),
          Enumerable.t()
        ) :: [BookingEvent.t()]
  defdelegate list_booking_events_for_range(
                user_id,
                start_dt,
                end_dt,
                cached_events \\ []
              ),
              to: BookingEvents,
              as: :list_for_range

  # How far ahead the desktop-reminder feed looks. Wide enough to cover the
  # longest reminder lead time (a week) while keeping the payload bounded.
  @reminder_feed_window_days 8

  @doc """
  Returns the user's upcoming timed events that carry at least one reminder,
  within `[now, now + #{@reminder_feed_window_days}d)`, scoped to the given
  integration IDs.

  `integrations` (the full structs, not just their ids) is used to drop rows
  from a calendar the user has since deselected. Selection is pushed into the
  query itself (see `Tymeslot.Integrations.Calendar.visibility_rules/1` and
  `ProviderCalendarEventQueries.list_upcoming_timed/4`) rather than filtered
  afterwards, so a busy deselected calendar can't crowd real matches out of
  the feed: the `LIMIT` only ever counts rows the caller can actually see.

  Reminders are normalised to the canonical `%{method:, minutes_before:}` shape,
  so callers can read `minutes_before` regardless of how the row was stored.

  ## Options

  - `:limit`: maximum number of rows to return (default: see
    `ProviderCalendarEventQueries.list_upcoming_timed/4`).
  """
  @spec list_upcoming_events_with_reminders([integer()], DateTime.t(), [map()], keyword()) ::
          [ProviderCalendarEventSchema.t()]
  def list_upcoming_events_with_reminders(integration_ids, now, integrations, opts \\ []) do
    window_end = DateTime.add(now, @reminder_feed_window_days, :day)
    rules = Calendar.visibility_rules(integrations)

    integration_ids
    |> ProviderCalendarEventQueries.list_upcoming_timed(
      now,
      window_end,
      Keyword.put(opts, :visibility_rules, rules)
    )
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
  `opts` to exclude calendars the user has toggled off entirely; results are
  ordered by start time and capped at a sensible limit. A blank term returns
  `[]`.

  `integrations` (the full structs, not just their ids) is used to drop rows
  from a calendar the user has *selectively* deselected, a finer grain than
  `:hidden_integration_ids`. Selection is pushed into the query itself (see
  `Tymeslot.Integrations.Calendar.visibility_rules/1` and
  `ProviderCalendarEventQueries.search/3`) rather than filtered afterwards, so
  a busy deselected calendar can't crowd real matches out of the results: the
  `LIMIT` only ever counts rows the caller can actually see.
  """
  @spec search_events(integer(), String.t(), [map()], keyword()) ::
          [ProviderCalendarEventSchema.t()]
  def search_events(user_id, term, integrations, opts \\ []) do
    rules = Calendar.visibility_rules(integrations)

    ProviderCalendarEventQueries.search(
      user_id,
      term,
      Keyword.put(opts, :visibility_rules, rules)
    )
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
    # The context call decrypts credentials; acceptable overhead for a
    # user-initiated refresh since we need id + provider for each integration.
    integrations = CalendarManagement.list_active_calendar_integrations(user_id)

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

  # The cached events schema stores start/end/synced_at as :utc_datetime_usec
  # and requires synced_at NOT NULL. The dashboard create flow builds datetimes
  # at second precision and doesn't always supply synced_at; it is writing what
  # it just committed, so "now" is the correct sync timestamp. synced_at is
  # upcast unconditionally so a caller-supplied second-precision value does not
  # fail Ecto's :utc_datetime_usec check.
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

  @doc """
  Applies `changes` to an existing event, writes the whole updated event to
  its provider, and records the edit on the cached row. See
  `Tymeslot.CalendarGrid.EventEdit.update_event/4`.
  """
  @spec update_event(pos_integer(), map(), EventEdit.changes(), keyword()) ::
          {:ok, map()} | {:error, EventEdit.failure()}
  defdelegate update_event(user_id, event, changes, opts \\ []), to: EventEdit

  @doc """
  Moves an event to another calendar, creating it on the destination before
  deleting the original. See `Tymeslot.CalendarGrid.EventMove.move_event/3`.
  """
  @spec move_event(pos_integer(), map(), EventMove.destination()) ::
          {:ok, EventMove.moved()} | {:error, term()}
  defdelegate move_event(user_id, event, destination), to: EventMove

  @doc """
  Gives an event a room on the organiser's video integration, or removes its
  video link when the integration is `nil`, on both the provider event and the
  cached row, or answers `{:ok, :unchanged}` when the choice is the one the
  event already has. See `Tymeslot.CalendarGrid.EventVideo.change_event_video/3`.
  """
  @spec change_event_video(pos_integer(), map(), pos_integer() | nil) ::
          {:ok, String.t() | nil | :unchanged}
          | {:error, :missing_meeting_url | :not_found | :linked_to_booking | term()}
  defdelegate change_event_video(user_id, event, video_integration_id), to: EventVideo

  @doc """
  An event as a successful video change wrote it: its new link, integration
  and description. See `Tymeslot.CalendarGrid.EventVideo.changed_event/4`.
  """
  @spec changed_event(pos_integer(), map(), pos_integer() | nil, String.t() | nil) :: map()
  defdelegate changed_event(user_id, event, video_integration_id, url), to: EventVideo

  @doc """
  Whether an event's video may be changed from the grid: not on the calendar
  copy of a booking, whose room belongs to the meeting. See
  `Tymeslot.CalendarGrid.EventVideo.ensure_video_changeable/1`.
  """
  @spec ensure_video_changeable(map()) :: :ok | {:error, :linked_to_booking}
  defdelegate ensure_video_changeable(event), to: EventVideo

  @doc """
  Returns `description` with the "Join video call" line for the previous URL
  taken out and one for the new URL appended. See
  `Tymeslot.CalendarGrid.EventVideo.put_join_link/3`.
  """
  @spec put_join_link(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t() | nil
  defdelegate put_join_link(description, previous_url, url), to: EventVideo

  @doc """
  Deletes an event from its calendar, cancels the Tymeslot meeting it was
  booked as, and removes its cached row. See
  `Tymeslot.CalendarGrid.EventDeletion.delete_event/2`.
  """
  @spec delete_event(pos_integer(), EventDeletion.event()) ::
          {:ok, EventDeletion.deleted()} | {:error, EventDeletion.failure()}
  defdelegate delete_event(user_id, event), to: EventDeletion

  @doc """
  Whether an event may be deleted from the grid. See
  `Tymeslot.CalendarGrid.EventDeletion.ensure_deletable/1`.
  """
  @spec ensure_deletable(map()) :: :ok | {:error, :recurring_event}
  defdelegate ensure_deletable(event), to: EventDeletion

  @doc """
  Whether an event may be moved to another calendar. See
  `Tymeslot.CalendarGrid.EventMove.ensure_movable/1`.
  """
  @spec ensure_movable(map()) :: :ok | {:error, :recurring_event}
  defdelegate ensure_movable(event), to: EventMove

  @doc """
  Whether an event may be edited from the grid. See
  `Tymeslot.CalendarGrid.EventEdit.ensure_editable/1`.
  """
  @spec ensure_editable(map()) :: :ok | {:error, :recurring_event}
  defdelegate ensure_editable(event), to: EventEdit

  @doc "Fetches a single cached event by integration ID and UID."
  @spec get_cached_event(integer(), String.t()) ::
          {:ok, CalendarEvent.t()} | {:error, :not_found}
  def get_cached_event(integration_id, uid) do
    case ProviderCalendarEventQueries.get_by_uid(integration_id, uid) do
      {:ok, record} -> {:ok, ProviderCalendarEventSchema.to_calendar_event(record)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # --- Video rooms of grid events (see `EventVideoRooms`) ---

  @doc "Records a video room made for a grid event. See `EventVideoRooms.record/2`."
  @spec record_event_video_room(map(), map()) :: :ok
  defdelegate record_event_video_room(meeting_context, event), to: EventVideoRooms, as: :record

  @doc "Brings a grid event's video rooms in step with its timing. See `EventVideoRooms.rescheduled/1`."
  @spec reschedule_event_video_rooms(map()) :: :ok
  defdelegate reschedule_event_video_rooms(event), to: EventVideoRooms, as: :rescheduled

  @doc "Follows a grid event moved to another integration. See `EventVideoRooms.moved/4`."
  @spec move_event_video_rooms(
          map(),
          pos_integer(),
          String.t(),
          String.t() | nil,
          String.t() | nil
        ) :: :ok
  defdelegate move_event_video_rooms(
                event,
                to_integration_id,
                new_uid,
                provider_uid,
                provider_calendar_id
              ),
              to: EventVideoRooms,
              as: :moved

  @doc "Deletes a deleted grid event's video rooms. See `EventVideoRooms.event_deleted/1`."
  @spec delete_event_video_rooms(map()) :: :ok
  defdelegate delete_event_video_rooms(event), to: EventVideoRooms, as: :event_deleted

  @doc "Whether an ended grid event's room may be deleted. See `EventVideoRooms.check_expired/1`."
  @spec check_event_video_room_expired(EventVideoRoomSchema.t()) :: :expired | :kept
  defdelegate check_event_video_room_expired(room), to: EventVideoRooms, as: :check_expired

  @doc "Whether an ended grid event's room may be deleted now. See `EventVideoRooms.confirm_expired/1`."
  @spec confirm_event_video_room_expired(EventVideoRoomSchema.t()) :: :expired | :kept
  defdelegate confirm_event_video_room_expired(room),
    to: EventVideoRooms,
    as: :confirm_expired

  @doc "A grid event's video room with its integrations loaded."
  @spec get_event_video_room(pos_integer()) ::
          {:ok, EventVideoRoomSchema.t()} | {:error, :not_found}
  defdelegate get_event_video_room(id), to: EventVideoRoomQueries, as: :get_with_integrations

  @doc "Removes the record of a grid event's video room once the room is gone."
  @spec forget_event_video_room(EventVideoRoomSchema.t()) :: :ok
  defdelegate forget_event_video_room(room), to: EventVideoRoomQueries, as: :delete

  @doc "Grid event video rooms whose event ended in a window. See `EventVideoRoomQueries.list_ended/4`."
  @spec list_ended_event_video_rooms([String.t()], DateTime.t(), DateTime.t()) ::
          [EventVideoRoomSchema.t()]
  defdelegate list_ended_event_video_rooms(providers, ended_before, ended_after),
    to: EventVideoRoomQueries,
    as: :list_ended

  # The grid event rooms a disconnect deletes: only those of a provider whose
  # rooms Tymeslot deletes after the meeting. A room held as a calendar event
  # of its own (a separate Teams event) is recorded to follow its grid event,
  # not to be swept up with the integration.
  @doc "A video integration's grid event rooms a disconnect deletes. See `EventVideoRoomQueries.list_for_integration/5`."
  @spec list_event_video_rooms_for_integration(
          pos_integer(),
          :upcoming | :all,
          DateTime.t(),
          pos_integer()
        ) :: [EventVideoRoomSchema.t()]
  def list_event_video_rooms_for_integration(integration_id, scope, now, limit) do
    EventVideoRoomQueries.list_for_integration(
      integration_id,
      VideoProviderConfig.rooms_deleted_after_meeting(),
      scope,
      now,
      limit
    )
  end

  @doc "How many grid event rooms a disconnect of a video integration deletes. See `EventVideoRoomQueries.count_for_integration/4`."
  @spec count_event_video_rooms_for_integration(pos_integer(), :upcoming | :all, DateTime.t()) ::
          non_neg_integer()
  def count_event_video_rooms_for_integration(integration_id, scope, now) do
    EventVideoRoomQueries.count_for_integration(
      integration_id,
      VideoProviderConfig.rooms_deleted_after_meeting(),
      scope,
      now
    )
  end

  @doc """
  Returns active calendar integrations for the given user.
  """
  @spec list_active_integrations(integer()) :: [CalendarIntegrationSchema.t()]
  def list_active_integrations(user_id) do
    CalendarManagement.list_active_calendar_integrations(user_id)
  end

  @doc """
  Returns calendar preferences for the given user, or a default struct if none exist.
  """
  @spec get_or_create_preferences(integer()) :: term()
  def get_or_create_preferences(user_id) do
    CalendarManagement.get_or_create_preferences(user_id)
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
    |> CalendarManagement.get_or_create_preferences()
    |> Map.get(:time_format)
    |> TimeFormat.resolve(locale)
  end

  @doc """
  Upserts calendar preferences for the given user.
  """
  @spec save_preferences(integer(), map()) :: {:ok, term()} | {:error, Ecto.Changeset.t()}
  def save_preferences(user_id, attrs) do
    CalendarManagement.save_preferences(user_id, attrs)
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
    SyncIcsCalendarWorker.enqueue(integration.id)
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
