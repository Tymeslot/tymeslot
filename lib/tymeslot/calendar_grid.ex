defmodule Tymeslot.CalendarGrid do
  @moduledoc """
  Context module for reading the calendar grid.

  Provides functions to fetch cached calendar events for a date range,
  search them, trigger background syncs for active integrations, assign
  stable display colours, and keep the organiser's calendar preferences.
  Changing an event (an edit, a move between calendars, a delete, its
  video, the series rules those follow) goes through
  `Tymeslot.CalendarGrid.Changes`.
  """

  alias Tymeslot.Availability
  alias Tymeslot.CalendarGrid.BookingEvent
  alias Tymeslot.CalendarGrid.BookingEvents
  alias Tymeslot.CalendarGrid.CalendarDirectory
  alias Tymeslot.CalendarGrid.EffectiveVisibility
  alias Tymeslot.CalendarGrid.EventSearch
  alias Tymeslot.CalendarGrid.EventVideoRoomPresence
  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.CalendarGrid.EventVideoRoomSchema
  alias Tymeslot.CalendarGrid.Freshness
  alias Tymeslot.CalendarGrid.IcsImport
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.Appearance
  alias Tymeslot.Integrations.Calendar.CalendarAppearanceSchema
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesSchema
  alias Tymeslot.Integrations.Calendar.EventColour
  alias Tymeslot.Integrations.Calendar.EventRole
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.Reminder
  alias Tymeslot.Integrations.Calendar.SeriesPreview
  alias Tymeslot.Integrations.Calendar.SyncSchedule
  alias Tymeslot.Integrations.HealthCheck
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

  A series the calendar has just written is cached as one row until its next
  sync; its later occurrences in the range are previewed from that row
  (`Tymeslot.Integrations.Calendar.SeriesPreview`), each saying so in
  `preview_of`.
  """
  @spec list_events_for_range([integer()], DateTime.t(), DateTime.t(), keyword()) ::
          [ProviderCalendarEventSchema.t()]
  def list_events_for_range(integration_ids, start_dt, end_dt, opts \\ []) do
    integration_ids
    |> ProviderCalendarEventQueries.list_for_range(start_dt, end_dt, opts)
    |> SeriesPreview.add(integration_ids, {start_dt, end_dt}, except_role: EventRole.busy_only())
    |> maybe_take(Keyword.get(opts, :limit))
    |> Enum.filter(&placeable?/1)
    |> Enum.map(&normalise_event_reminders/1)
  end

  @doc """
  The series a previewed occurrence belongs to, as its cached row; any other
  event as it is. See `Tymeslot.Integrations.Calendar.SeriesPreview`.
  """
  @spec preview_series(map()) :: map()
  defdelegate preview_series(event), to: SeriesPreview, as: :series

  @doc "Whether `event` is a previewed occurrence. See `Tymeslot.Integrations.Calendar.SeriesPreview`."
  @spec preview?(map()) :: boolean()
  defdelegate preview?(event), to: SeriesPreview

  # Previewed occurrences join the rows after the read's own limit, so the
  # limit is applied again, keeping the earliest as the read does.
  defp maybe_take(events, nil), do: events
  defp maybe_take(events, limit), do: Enum.take(events, limit)

  # The cache's writers refuse a half-timed row, but one stored before they
  # did would crash the grid's layout (a timed event without an end has
  # nowhere to stop), so it is left out and logged instead. Search leaves such
  # rows out in its query (`ProviderCalendarEventSearchQueries.search_around/3`).
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
  into the grid's event shape. See
  `Tymeslot.CalendarGrid.BookingEvents.list_for_range/4`. `opts` as that
  function takes them.
  """
  @spec list_booking_events_for_range(pos_integer(), DateTime.t(), DateTime.t(), keyword()) ::
          [BookingEvent.t()]
  defdelegate list_booking_events_for_range(user_id, start_dt, end_dt, opts \\ []),
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

  Reminders are normalised as in `list_events_for_range/4`.

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
    |> SeriesPreview.add(integration_ids, {now, window_end},
      visibility_rules: rules,
      except_role: EventRole.busy_only(),
      timed_only: true
    )
    |> Enum.filter(&starts_within?(&1, now, window_end))
    |> Enum.map(&normalise_event_reminders/1)
    |> Enum.reject(&(&1.reminders == []))
  end

  # The feed is of events still to start; a previewed occurrence is computed
  # over the window it overlaps.
  defp starts_within?(%{start_at: %DateTime{} = start_at}, now, window_end),
    do: DateTime.compare(start_at, now) != :lt and DateTime.compare(start_at, window_end) == :lt

  defp starts_within?(_event, _now, _window_end), do: false

  # The reminders column is nullable, so a row written without one loads as nil
  # rather than an empty list.
  defp normalise_event_reminders(%{reminders: nil} = event),
    do: %{event | reminders: []}

  defp normalise_event_reminders(event),
    do: %{event | reminders: Enum.map(event.reminders, &Reminder.normalise/1)}

  @doc """
  The calendar's search: events nearest to now first, a repeating event once,
  bookings by their guest and in place of their calendar copies, calendars
  the organiser has hidden (or left out of the active set) excluded. See
  `Tymeslot.CalendarGrid.EventSearch.search/5`.
  """
  @spec search_calendar(integer(), String.t(), [map()], EffectiveVisibility.t(), keyword()) ::
          %{events: [EventSearch.hit()], bookings: [EventSearch.hit()]}
  defdelegate search_calendar(user_id, term, integrations, visibility, opts),
    to: EventSearch,
    as: :search

  @doc "The consecutive failed sync cycles of each of the user's calendar integrations, by id."
  @spec sync_failures(integer()) :: %{integer() => pos_integer()}
  def sync_failures(user_id), do: HealthCheck.sync_failure_counts(:calendar, user_id)

  @doc "Enqueues a sync of one of the user's active integrations. See `Freshness.request_sync/3`."
  defdelegate request_sync(user_id, integration_id, how \\ :requested), to: Freshness

  @doc "The integrations whose cached events are stale. See `Freshness.stale_integrations/1`."
  defdelegate stale_integrations(integrations), to: Freshness

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
  Tailwind classes for an account's calendars, keyed by
  `{integration_id, provider_calendar_id}`. The calendar paints from
  this map, so one calendar never takes two colours.

  A calendar the organiser gave a colour keeps it. An account's first synced
  calendar is otherwise absent, so the caller falls through to the account's
  colour. Every further calendar of the account takes a rotation class that no
  account and no chosen calendar uses yet, so two calendars of one account
  never paint alike while the rotation lasts. Accounts are walked in id order,
  as the account rotation is, so the result does not depend on the order the
  integrations are passed in.
  """
  @spec calendar_colour_classes([map()], [CalendarAppearanceSchema.t()]) :: %{
          {integer(), String.t()} => String.t()
        }
  def calendar_colour_classes(integrations, appearances) do
    chosen =
      appearances
      |> Enum.filter(&Appearance.chosen?/1)
      |> Map.new(fn appearance ->
        {{appearance.calendar_integration_id, appearance.provider_calendar_id},
         EventColour.tailwind_class(appearance.colour)}
      end)

    extras =
      for integration <- Enum.sort_by(integrations, & &1.id),
          {entry, index} <- Enum.with_index(CalendarDirectory.synced_entries(integration)),
          key = {integration.id, entry.id},
          index > 0 and not Map.has_key?(chosen, key),
          do: key

    taken =
      MapSet.new(Map.values(integration_colour_classes(integrations)) ++ Map.values(chosen))

    extras
    |> Enum.zip(Stream.cycle(spare_rotation_classes(taken)))
    |> Map.new()
    |> Map.merge(chosen)
  end

  # The rotation classes nothing paints with yet, or the whole rotation once
  # every one is taken.
  defp spare_rotation_classes(taken) do
    rotation = Enum.map(1..EventColour.rotation_size(), &EventColour.rotation_class/1)

    case Enum.reject(rotation, &MapSet.member?(taken, &1)) do
      [] -> rotation
      spare -> spare
    end
  end

  # A blank colour is treated as no colour, not as an unrecognised one: it can
  # only reach the column from outside the changeset (a restore, a hand-written
  # UPDATE), and rotating is a better answer there than painting it neutral.
  defp colour_class(%{colour: colour}, _index) when is_binary(colour) and colour != "",
    do: EventColour.tailwind_class(colour)

  defp colour_class(_integration, index),
    do: EventColour.rotation_class(rem(index, EventColour.rotation_size()) + 1)

  @doc "Parses an uploaded `.ics` file into an import plan. See `IcsImport.plan/2`."
  defdelegate plan_ics_import(content, timezone), to: IcsImport, as: :plan

  @doc "Whether an `.ics` import of the user's is under way. See `IcsImport.running?/1`."
  defdelegate ics_import_running?(user_id), to: IcsImport, as: :running?

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
  A cached event as an attendee update email describes it: the
  `CalendarEvent` fields as a map, plus the `video_link` the row keeps
  beside them, which the struct does not carry.
  """
  @spec get_cached_event_with_video(integer(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_cached_event_with_video(integration_id, uid) do
    with {:ok, record} <- ProviderCalendarEventQueries.get_by_uid(integration_id, uid) do
      {:ok,
       record
       |> ProviderCalendarEventSchema.to_calendar_event()
       |> Map.from_struct()
       |> Map.put(:video_link, record.video_link)}
    end
  end

  # --- Video rooms of grid events (see `EventVideoRooms`) ---

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

  @doc "The densities a calendar grid can be drawn in."
  @spec densities() :: [String.t()]
  defdelegate densities(), to: CalendarPreferencesSchema, as: :densities

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
