defmodule Tymeslot.CalendarGrid do
  @moduledoc """
  Context module for the calendar grid view.

  Provides functions to fetch cached calendar events for a date range,
  trigger background syncs for active integrations, and assign stable
  display colours to integrations.
  """

  alias Tymeslot.Availability
  alias Tymeslot.CalendarGrid.BookingEvent
  alias Tymeslot.CalendarGrid.BookingEvents
  alias Tymeslot.CalendarGrid.EventDeletion
  alias Tymeslot.CalendarGrid.EventEdit
  alias Tymeslot.CalendarGrid.EventMove
  alias Tymeslot.CalendarGrid.EventVideo
  alias Tymeslot.CalendarGrid.EventVideoRoomPresence
  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.CalendarGrid.EventVideoRoomSchema
  alias Tymeslot.CalendarGrid.Freshness
  alias Tymeslot.CalendarGrid.IcsImport
  alias Tymeslot.CalendarGrid.RepeatRefusal
  alias Tymeslot.CalendarGrid.SeriesCarry
  alias Tymeslot.CalendarGrid.SeriesEdit
  alias Tymeslot.CalendarGrid.SeriesStart
  alias Tymeslot.CalendarGrid.WriteQueue.SeriesActivity
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.Appearance
  alias Tymeslot.Integrations.Calendar.CalendarAppearanceSchema
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.EventColour
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Reminder
  alias Tymeslot.Integrations.Calendar.SyncSchedule
  alias Tymeslot.Integrations.Video.ProviderConfig, as: VideoProviderConfig
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat

  require Logger

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
    |> Enum.filter(&placeable?/1)
    |> Enum.map(&normalise_event_reminders/1)
  end

  # The cache's writers refuse a half-timed row, but one stored before they
  # did would crash the grid's layout (a timed event without an end has
  # nowhere to stop), so it is left out and logged instead. Search leaves such
  # rows out in its query (`ProviderCalendarEventQueries.search/3`).
  defp placeable?(%ProviderCalendarEventSchema{} = row) do
    complete? = ProviderCalendarEventSchema.timing_complete?(Map.from_struct(row))

    unless complete? do
      Logger.warning("Calendar grid skipped a cached event with incomplete timing",
        provider_calendar_event_id: row.id,
        calendar_integration_id: row.calendar_integration_id,
        all_day: row.all_day
      )
    end

    complete?
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

  @doc "Enqueues a sync of each of the user's active integrations. See `Freshness.refresh_events/2`."
  defdelegate refresh_events(user_id, how \\ :requested), to: Freshness

  @doc "The integrations whose cached events are stale. See `Freshness.stale_integrations/1`."
  defdelegate stale_integrations(integrations), to: Freshness

  @doc "The oldest sync among the integrations. See `Freshness.oldest_sync_at/1`."
  defdelegate oldest_sync_at(integrations), to: Freshness

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
  Inserts a newly created event into the local cache so it appears
  immediately without waiting for the next sync cycle.

  Accepts a map with `:uid`, `:calendar_integration_id`, `:title`,
  `:start_at`, `:end_at`, and optionally `:all_day`. A recurring event's
  video is handed on to the occurrences its first sync caches
  (`SeriesCarry.series_created/1`).
  """
  @spec cache_created_event(map()) :: :ok
  def cache_created_event(attrs) do
    {:ok, _count} = ProviderCalendarEventQueries.upsert_batch([normalise_cache_attrs(attrs)])
    SeriesCarry.series_created(attrs)
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

  @doc "Parses an uploaded `.ics` file into an import plan. See `IcsImport.plan/2`."
  defdelegate plan_ics_import(content, timezone), to: IcsImport, as: :plan

  @doc "Whether an `.ics` import of the user's is under way. See `IcsImport.running?/1`."
  defdelegate ics_import_running?(user_id), to: IcsImport, as: :running?

  @doc """
  Whether the write queue is still writing to the series `event` belongs to.
  See `SeriesActivity.saving?/2`.
  """
  defdelegate series_saving?(queue, event), to: SeriesActivity, as: :saving?

  @doc """
  Whether the write queue is writing to another event of the series `event`
  belongs to. See `SeriesActivity.busy?/2`.
  """
  defdelegate series_busy?(queue, event), to: SeriesActivity, as: :busy?

  @doc """
  Writes an import plan to one of the user's calendars (see `IcsImport.run/3`),
  then drops the user's cached availability and syncs the calendar, so the
  imported events block their time and appear on the grid. While another
  import of the user's runs, it returns `{:error, :already_running}`.
  """
  @spec import_ics(pos_integer(), pos_integer(), String.t() | nil, IcsImport.plan(), keyword()) ::
          {:ok, IcsImport.summary()} | {:error, :not_found | IcsImport.import_error()}
  def import_ics(user_id, integration_id, calendar_id, plan, opts \\ []) do
    with {:ok, target} <- IcsImport.target(user_id, integration_id, calendar_id) do
      IcsImport.exclusively(user_id, fn ->
        summary = IcsImport.run(target, plan, opts)

        if summary.created > 0 do
          Availability.changed(user_id)
          SyncSchedule.request_sync(target.integration)
        end

        {:ok, summary}
      end)
    end
  end

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
  deleting the original; a member of a series moves the whole series. See
  `Tymeslot.CalendarGrid.EventMove.move_event/3`.
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
  Deletes an event from its calendar, cancels the Tymeslot meeting it was
  booked as, and removes its cached row; for a member of a series, `scope`
  says whether one occurrence or the whole series goes. See
  `Tymeslot.CalendarGrid.EventDeletion.delete_event/4`, also for `opts`.
  """
  @spec delete_event(pos_integer(), EventDeletion.event(), EventDeletion.scope(), keyword()) ::
          {:ok, EventDeletion.deleted()} | {:error, EventDeletion.failure()}
  defdelegate delete_event(user_id, event, scope \\ :occurrence, opts \\ []), to: EventDeletion

  @doc """
  How an event may be deleted from the grid: on its own, in a scope, or not
  at all. See `Tymeslot.CalendarGrid.EventDeletion.deletion_scopes/1`.
  """
  @spec deletion_scopes(map()) :: {:ok, :single | :series} | {:error, :recurring_event}
  defdelegate deletion_scopes(event), to: EventDeletion

  @doc """
  Whether an event may be moved to another calendar: on its own, with its
  whole series, or not at all. See
  `Tymeslot.CalendarGrid.EventMove.ensure_movable/1`.
  """
  @spec ensure_movable(map()) :: :ok | {:ok, :series} | {:error, :recurring_event}
  defdelegate ensure_movable(event), to: EventMove

  @doc """
  Whether the series an event belongs to can move to an integration, and
  what the move will not carry. See
  `Tymeslot.CalendarGrid.EventMove.series_move_notes/2`.
  """
  @spec series_move_notes(map(), map()) :: {:ok, [atom()]} | {:error, atom()}
  defdelegate series_move_notes(event, integration), to: EventMove

  @doc """
  How an event may be edited from the grid: on its own, in a scope, or, for
  a series whose provider has no scoped edit, as that one event only. See
  `Tymeslot.CalendarGrid.EventEdit.edit_scopes/1`.
  """
  @spec edit_scopes(map()) :: {:ok, :single | :this_only | :series}
  defdelegate edit_scopes(event), to: EventEdit

  @doc """
  Whether the grid can give an event of `provider` a repeat rule, or change
  the one it has (see `ProviderConfig.writes_repeat_rules?/1`).
  """
  @spec repeatable_provider?(atom() | String.t() | nil) :: boolean()
  defdelegate repeatable_provider?(provider), to: ProviderConfig, as: :writes_repeat_rules?

  @doc """
  The first start of the series `event` belongs to, which a whole-series
  repeat pattern is written against (see `SeriesStart.of/1`).
  """
  @spec series_start(map()) :: Date.t() | DateTime.t() | nil
  defdelegate series_start(event), to: SeriesStart, as: :of

  @doc """
  Where the series put `event`, which a change of it and the following
  occurrences splits the series at (see `SeriesStart.slot/1`).
  """
  @spec occurrence_slot(map()) :: Date.t() | DateTime.t() | nil
  defdelegate occurrence_slot(event), to: SeriesStart, as: :slot

  @doc """
  The rule an edit of `event` and every following occurrence writes to the
  series it starts, given the new `rule` with its `COUNT` as given for the
  whole series: the `COUNT` less the occurrences before the split, counted
  on the wall clock of `zone` (see `SeriesEdit.following_rule/3`).
  """
  @spec following_rule(map(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :ends_before | :start_unknown}
  defdelegate following_rule(event, rule, zone), to: SeriesEdit

  @doc """
  Why a calendar of `provider` would refuse `rule` for a series starting on
  `start_date`, or `nil` (see `RepeatRefusal.reason/4`).
  """
  @spec repeat_refusal(atom() | String.t() | nil, String.t() | nil, Date.t(), String.t() | nil) ::
          RepeatRefusal.reason() | nil
  defdelegate repeat_refusal(provider, rule, start_date, timezone),
    to: RepeatRefusal,
    as: :reason

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

  @doc "Grid event video rooms whose event seems deleted outside the grid. See `EventVideoRoomPresence.list_gone/0`."
  @spec list_gone_event_video_rooms() :: [EventVideoRoomSchema.t()]
  defdelegate list_gone_event_video_rooms, to: EventVideoRoomPresence, as: :list_gone

  @doc "Whether a grid event's room lost its event, asking its provider. See `EventVideoRoomPresence.confirm/1`."
  @spec confirm_event_video_room_gone(EventVideoRoomSchema.t()) :: :gone | :kept
  defdelegate confirm_event_video_room_gone(room), to: EventVideoRoomPresence, as: :confirm

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
    Management.list_active_calendar_integrations(user_id)
  end

  @doc """
  Returns calendar preferences for the given user, or a default struct if none exist.
  """
  @spec get_or_create_preferences(integer()) :: term()
  def get_or_create_preferences(user_id) do
    Management.get_or_create_preferences(user_id)
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
    |> Management.get_or_create_preferences()
    |> Map.get(:time_format)
    |> TimeFormat.resolve(locale)
  end

  @doc """
  Upserts calendar preferences for the given user.
  """
  @spec save_preferences(integer(), map()) :: {:ok, term()} | {:error, Ecto.Changeset.t()}
  def save_preferences(user_id, attrs) do
    Management.save_preferences(user_id, attrs)
  end
end
