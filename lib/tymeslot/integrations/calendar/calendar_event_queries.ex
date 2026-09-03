defmodule Tymeslot.Integrations.Calendar.CalendarEventQueries do
  @moduledoc """
  The event cache expressed in canonical `CalendarEvent` terms.

  Reads convert results via
  `ProviderCalendarEventSchema.to_calendar_event/1`, so callers work with
  domain structs rather than database records; the one write here converts the
  other way. `ProviderCalendarEventQueries` remains the row-level module for
  the same table.

  It is also where the `role` column is honoured on both sides: `in_range/2`
  is the availability read and `full_refresh_for_role/3` the replacement a
  provider with more than one read path needs.
  `list_blocking_for_range/3` is `in_range/2`'s one departure from the
  canonical-struct rule, and exists so the role filter is written once rather
  than once per shape; see its own doc.
  """

  import Ecto.Query

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.EventRole
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
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

  The `DateTime` clause is `list_blocking_for_range/3` converted to structs, so
  the role filter this read applies is defined once rather than once per shape.

  Returns a list of `CalendarEvent` structs.
  """
  @spec in_range([integer()], {DateTime.t(), DateTime.t()} | {Date.t(), Date.t()}) ::
          [CalendarEvent.t()]
  def in_range([], _range), do: []

  def in_range(integration_ids, {%DateTime{} = range_start, %DateTime{} = range_end}) do
    integration_ids
    |> list_blocking_for_range(range_start, range_end)
    |> Enum.map(&ProviderCalendarEventSchema.to_calendar_event/1)
  end

  def in_range(integration_ids, {%Date{} = range_start, %Date{} = range_end}) do
    range_start_dt = DateTime.new!(range_start, ~T[00:00:00], "Etc/UTC")
    range_end_dt = DateTime.new!(Date.add(range_end, 1), ~T[00:00:00], "Etc/UTC")

    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id in ^integration_ids)
    |> where([e], e.role != ^@role_display_only)
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
  `CalendarEvent.blocking?/1` matches on for plain maps, and the atoms a
  `CalendarEvent` carries would make every transparent or cancelled row block.
  """
  @spec list_blocking_for_range([integer()], DateTime.t(), DateTime.t()) :: [
          ProviderCalendarEventSchema.t()
        ]
  def list_blocking_for_range([], _range_start, _range_end), do: []

  def list_blocking_for_range(integration_ids, range_start, range_end) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id in ^integration_ids)
    |> where([e], e.role != ^@role_display_only)
    |> ProviderCalendarEventQueries.where_overlapping_range(range_start, range_end)
    |> Repo.all()
  end

  @doc """
  Replaces every cached row an integration holds under `role`, in one
  transaction.

  The scoped counterpart to
  `ProviderCalendarEventQueries.full_refresh_for_integration/2`, and the only
  refresh an integration with two read paths may use. Exchange has two:
  `GetUserAvailability` writes the `busy_only` rows and the item path writes
  the `display_only` ones, both under the same integration id, so the unscoped
  refresh would have each half delete the other's rows on every cycle —
  intermittently, and with nothing to say so. Takes the same advisory lock, on
  the same key, so the two halves still serialise against each other.
  """
  @spec full_refresh_for_role(integer(), String.t(), [CalendarEvent.t()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def full_refresh_for_role(calendar_integration_id, role, calendar_events)
      when role in @roles and is_list(calendar_events) do
    attrs =
      Enum.map(calendar_events, fn event ->
        event
        |> ProviderCalendarEventSchema.from_calendar_event()
        |> Map.put(:role, role)
      end)

    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [2, calendar_integration_id])

      ProviderCalendarEventSchema
      |> where([e], e.calendar_integration_id == ^calendar_integration_id and e.role == ^role)
      |> Repo.delete_all()

      {:ok, count} = ProviderCalendarEventQueries.upsert_batch(attrs)
      count
    end)
  end

  @doc """
  Says whether the integration already holds a row of `role` overlapping the
  window.

  The role-scoped input to a sync worker's empty-response guard: a run that
  read no busy intervals must be judged against the busy rows it is about to
  replace, not against the item rows it is not touching.
  """
  @spec any_in_range_for_role?(integer(), String.t(), DateTime.t(), DateTime.t()) :: boolean()
  def any_in_range_for_role?(calendar_integration_id, role, range_start, range_end)
      when role in @roles do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^calendar_integration_id and e.role == ^role)
    |> ProviderCalendarEventQueries.where_overlapping_range(range_start, range_end)
    |> Repo.exists?()
  end
end
