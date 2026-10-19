defmodule Tymeslot.Integrations.Calendar.CalendarEventQueries do
  @moduledoc """
  The event cache expressed in canonical `CalendarEvent` terms.

  Reads convert results via
  `ProviderCalendarEventSchema.to_calendar_event/1`, so callers work with
  domain structs rather than database records. `ProviderCalendarEventQueries`
  remains the row-level module for the same table, and
  `IntegrationCacheQueries.replace_cached_rows/3` the replacement a provider
  with more than one read path makes, one role at a time.

  It is also where the `role` column is honoured on the read side:
  `in_range/2` is the availability read.
  `list_blocking_for_range/3` is `in_range/2`'s one departure from the
  canonical-struct rule, and exists so the role filter is written once rather
  than once per shape; see its own doc.
  """

  import Ecto.Query

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.EventRole
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries.Visibility
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Repo

  # Bound at compile time from the module that owns the column's vocabulary, so
  # a rename cannot leave a stale literal behind in a `where` clause that would
  # then silently match nothing.
  @role_display_only EventRole.display_only()
  @roles EventRole.all()

  @doc """
  Returns all cached events for the given integration IDs that overlap the range.

  Accepts either a `{DateTime, DateTime}` or `{Date, Date}` range tuple.
  Both timed and all-day events are checked for overlap.

  This is the **availability** read, so `display_only` rows are excluded. Such
  a row describes an event the grid should render but whose times cannot be
  trusted to block: Exchange's item path answers a recurring series as a
  single master dated to its first occurrence, so blocking on it would free up
  every later occurrence. The busy time for those integrations arrives
  separately as `busy_only` rows, which this read does return.
  `ProviderCalendarEventQueries.list_for_range/4` excludes the other side.
  Every provider but Exchange writes only `both` rows, so neither filter
  changes what they return.

  The `DateTime` clause is `list_blocking_for_range/4` converted to structs, so
  the role filter this read applies is defined once rather than once per shape.

  `blocking_rules`, from `AvailabilityView.rules/1`, keeps only rows from
  calendars the owner lets block availability; it also drops rows a sync left
  behind for a calendar since deselected. Every availability read passes it;
  `%{}` keeps every calendar's rows.

  Returns a list of `CalendarEvent` structs.
  """
  @spec in_range(
          [integer()],
          {DateTime.t(), DateTime.t()} | {Date.t(), Date.t()},
          %{integer() => Selection.visibility_rule()}
        ) :: [CalendarEvent.t()]
  def in_range(integration_ids, range, blocking_rules \\ %{})

  def in_range([], _range, _blocking_rules), do: []

  def in_range(
        integration_ids,
        {%DateTime{} = range_start, %DateTime{} = range_end},
        blocking_rules
      ) do
    integration_ids
    |> list_blocking_for_range(range_start, range_end, blocking_rules)
    |> Enum.map(&ProviderCalendarEventSchema.to_calendar_event/1)
  end

  def in_range(integration_ids, {%Date{} = range_start, %Date{} = range_end}, blocking_rules) do
    range_start_dt = DateTime.new!(range_start, ~T[00:00:00], "Etc/UTC")
    range_end_dt = DateTime.new!(Date.add(range_end, 1), ~T[00:00:00], "Etc/UTC")

    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id in ^integration_ids)
    |> where([e], e.role != ^@role_display_only)
    |> where([e], ^Visibility.dynamic_for(blocking_rules))
    |> where(
      [e],
      (e.all_day == false and e.start_at < ^range_end_dt and e.end_at > ^range_start_dt) or
        (e.all_day == true and e.start_date <= ^range_end and e.end_date > ^range_start)
    )
    |> Repo.all()
    |> Enum.map(&ProviderCalendarEventSchema.to_calendar_event/1)
  end

  @doc """
  Returns the cached rows for the given integration IDs that overlap the range
  and are allowed to block availability.

  This is the **availability** read at row level: `display_only` rows are
  excluded, because such a row describes an event the grid should render but
  whose times cannot be trusted to block — Exchange's item path answers a
  recurring series as a single master dated to its first occurrence, so
  blocking on it would free up every later occurrence. `busy_only` rows, which
  the display read excludes, are returned here.

  `in_range/2` is the same read in canonical `CalendarEvent` terms and is
  defined in terms of this one, so the two cannot disagree about which rows may
  block. Providers whose `list_events/2` reads the cache call this directly
  rather than `in_range/2`, because they must hand back the database's own
  string-valued `status`/`transparency`: that is the shape
  `CalendarEvent` carries would make every transparent or cancelled row block.

  `blocking_rules` as for `in_range/3`.
  """
  @spec list_blocking_for_range(
          [integer()],
          DateTime.t(),
          DateTime.t(),
          %{integer() => Selection.visibility_rule()}
        ) :: [ProviderCalendarEventSchema.t()]
  def list_blocking_for_range(integration_ids, range_start, range_end, blocking_rules \\ %{})

  def list_blocking_for_range([], _range_start, _range_end, _blocking_rules), do: []

  def list_blocking_for_range(integration_ids, range_start, range_end, blocking_rules) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id in ^integration_ids)
    |> where([e], e.role != ^@role_display_only)
    |> where([e], ^Visibility.dynamic_for(blocking_rules))
    |> ProviderCalendarEventQueries.where_overlapping_range(range_start, range_end)
    |> Repo.all()
  end

  @doc """
  Says whether the integration already holds a row overlapping the window:
  a row of `role`, or of any role when `role` is nil.

  The input to a sync's empty-response guard. Scoped to a role, a run that
  read no busy intervals is judged against the busy rows it is about to
  replace, not against the item rows it is not touching.
  """
  @spec any_in_range?(integer(), String.t() | nil, DateTime.t(), DateTime.t()) :: boolean()
  def any_in_range?(calendar_integration_id, role, range_start, range_end)
      when is_nil(role) or role in @roles do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^calendar_integration_id)
    |> where_role(role)
    |> ProviderCalendarEventQueries.where_overlapping_range(range_start, range_end)
    |> Repo.exists?()
  end

  defp where_role(query, nil), do: query
  defp where_role(query, role), do: where(query, [e], e.role == ^role)
end
