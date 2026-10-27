defmodule Tymeslot.Integrations.Calendar.SeriesRules do
  @moduledoc """
  The repeat rules of the Google and Outlook series an integration's cache
  holds occurrences of.

  Both providers list a series as its single occurrences, each naming its
  master in `recurring_event_id` and none saying how the series repeats. The
  rule lives on the master, so it is kept apart (`calendar_series_rules`, one
  row per series) and copied onto every occurrence as it is cached
  (`stamp/2`), which is what lets the grid show the pattern and edit it.

  ## What the copy is for

  A stamped rule describes the series an occurrence belongs to; it never
  makes the occurrence one. Nothing expands a cached row's rule: the cache
  holds every occurrence already, and the availability read drops the rule
  (`ProviderCalendarEventSchema`). A write to one occurrence sends no rule
  (`Tymeslot.CalendarGrid.SeriesEdit`).

  CalDAV occurrences name no master and carry their resource's rule already,
  so none of this applies to them.
  """

  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.IntegrationCacheQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarSeriesQueries
  alias Tymeslot.Integrations.Calendar.SeriesRuleQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  require Logger

  # The most masters one call reads. Every read is also charged to the
  # integration's `:series_rule_read` limit (50 in ten minutes), which is
  # what holds a whole sync cycle, and concurrent ones, to that many.
  @max_reads_per_window 50

  # A master not named by a change is read again once its rule is this old.
  @fresh_for_seconds 24 * 60 * 60

  @typedoc """
  Reads one master, given its id and the calendar an occurrence of it is in
  (nil when not known): its rule (nil when it is not a series) and first start,
  `:gone` when the provider no longer has it, or `{:stop, reason}` when no
  further master should be read this run (throttled, refused, unreachable).
  """
  @type read ::
          (String.t(), String.t() | nil ->
             {:ok, %{rule: String.t() | nil, master_start: DateTime.t() | nil}}
             | :gone
             | {:stop, term()})

  @doc """
  Reads the series' masters a sync needs and stores what each read found.
  Called before `calendar_events` are cached, so they are stamped with it.

  With `changed: true` the events are a batch of changes (a delta, a pushed
  change), so every master they name is read, however fresh its rule: its
  series changed. Otherwise they are a listing, which says nothing changed,
  and only masters whose rule was never read or is a day old are read. Then
  the masters of cached series in that state.

  Each read is charged to the integration's `:series_rule_read` rate limit
  before it is made, whatever it then answers, so an integration's masters
  are read at most 50 times in ten minutes across every call a sync cycle
  makes, and across concurrent syncs, failed reads included. Never fails: a
  read that cannot be made, or the spent budget, stops the rest for this
  run, and the occurrences are cached as they would be without it.
  """
  @spec refresh(integer(), [map()], read(), keyword()) :: :ok
  def refresh(integration_id, calendar_events, read, opts \\ []) do
    now = DateTime.truncate(Clock.utc_now(), :second)
    stale_before = DateTime.add(now, -@fresh_for_seconds, :second)

    named = named_masters(calendar_events)
    due = due_named(integration_id, named, stale_before, Keyword.get(opts, :changed, false))
    due_ids = Enum.map(due, &elem(&1, 0))
    room = max(@max_reads_per_window - length(due), 0)

    (due ++ SeriesRuleQueries.masters_to_refresh(integration_id, stale_before, due_ids, room))
    |> Enum.take(@max_reads_per_window)
    |> Enum.reduce_while(:ok, fn {master_id, calendar_id}, :ok ->
      with :ok <- charge(integration_id),
           result = read.(master_id, calendar_id),
           :ok <- stored(integration_id, master_id, result) do
        {:cont, :ok}
      else
        {:stop, reason} ->
          Logger.warning("Stopped reading series rules for this sync run",
            calendar_integration_id: integration_id,
            reason: LogFormat.reason(reason)
          )

          {:halt, :ok}
      end
    end)
  end

  # Every read is charged before it is made, whatever it then answers, so
  # failures spend the budget as successes do.
  defp charge(integration_id) do
    case RateLimiter.check(:series_rule_read, integration_id) do
      :ok -> :ok
      {:error, _limited, _message} -> {:stop, :read_budget_spent}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp stored(integration_id, master_id, {:ok, found}),
    do: store(integration_id, master_id, found)

  defp stored(integration_id, master_id, :gone),
    do: store(integration_id, master_id, %{rule: nil, master_start: nil})

  defp stored(_integration_id, _master_id, {:stop, _reason} = stop), do: stop

  defp due_named(_integration_id, named, _stale_before, true = _changed), do: named

  defp due_named(integration_id, named, stale_before, false = _changed) do
    stored = SeriesRuleQueries.list_by_master(integration_id, Enum.map(named, &elem(&1, 0)))

    Enum.filter(named, fn {master_id, _calendar_id} ->
      case Map.fetch(stored, master_id) do
        {:ok, row} -> DateTime.before?(row.fetched_at, stale_before)
        :error -> true
      end
    end)
  end

  # Each master the events name, with the calendar its first named
  # occurrence is in.
  defp named_masters(calendar_events) do
    calendar_events
    |> Enum.filter(&(is_binary(&1.recurring_event_id) and &1.recurring_event_id != ""))
    |> Enum.uniq_by(& &1.recurring_event_id)
    |> Enum.map(&{&1.recurring_event_id, &1.provider_calendar_id})
  end

  # A read that cannot be stored is skipped, like one that cannot be made: a
  # rule read never fails the sync it runs in.
  defp store(integration_id, master_id, found) do
    attrs = Map.put(found, :fetched_at, DateTime.truncate(Clock.utc_now(), :second))

    # Under the cache lock, so the occurrences cached since the last read get
    # the rule without racing an upsert of them.
    result =
      IntegrationCacheQueries.under_lock(integration_id, fn ->
        case SeriesRuleQueries.put(integration_id, master_id, attrs) do
          {:ok, _row} ->
            ProviderCalendarSeriesQueries.put_occurrence_rule(
              integration_id,
              master_id,
              found.rule
            )

          {:error, changeset} ->
            Repo.rollback(changeset.errors)
        end
      end)

    case result do
      {:ok, _count} -> :ok
      {:error, reason} -> log_store_failure(integration_id, reason)
    end
  rescue
    exception -> log_store_failure(integration_id, exception)
  end

  defp log_store_failure(integration_id, reason) do
    Logger.error("A series rule read could not be stored",
      calendar_integration_id: integration_id,
      reason: LogFormat.reason(reason)
    )

    :ok
  end

  @doc """
  Gives every occurrence in `calendar_events` that names a master with a
  stored rule, and carries no rule of its own, that rule. One read for the
  batch.
  """
  @spec stamp(integer(), [CalendarEvent.t()]) :: [CalendarEvent.t()]
  def stamp(integration_id, calendar_events) do
    rules =
      SeriesRuleQueries.list_by_master(integration_id, master_ids(calendar_events))

    Enum.map(calendar_events, fn
      %{recurrence_rule: nil, recurring_event_id: master_id} = event
      when is_map_key(rules, master_id) ->
        %{event | recurrence_rule: Map.fetch!(rules, master_id).rule}

      event ->
        event
    end)
  end

  @doc """
  Forgets the rules of the series the integration's cache no longer holds an
  occurrence of, once occurrences have been deleted from it.
  """
  @spec forget_orphans(integer()) :: :ok
  def forget_orphans(integration_id) do
    SeriesRuleQueries.delete_orphans(integration_id)
    :ok
  end

  @doc """
  Gives each event in `events` (or the one event) that names a master with a
  stored rule its series' first start, as `:series_start`, which is what a
  `COUNT` is counted from (`Tymeslot.CalendarGrid.EventVideoRoomTimes`). One
  read for the list; an event without one is returned as it was.
  """
  @spec with_series_start([map()]) :: [map()]
  @spec with_series_start(map()) :: map()
  def with_series_start(events) when is_list(events) do
    starts =
      events
      |> Enum.group_by(&Map.get(&1, :calendar_integration_id))
      |> Enum.flat_map(fn
        {nil, _not_cached} -> []
        {integration_id, of_integration} -> series_starts(integration_id, of_integration)
      end)
      |> Map.new()

    Enum.map(events, fn event ->
      key = {Map.get(event, :calendar_integration_id), Map.get(event, :recurring_event_id)}

      case Map.get(starts, key) do
        %DateTime{} = series_start -> Map.put(event, :series_start, series_start)
        nil -> event
      end
    end)
  end

  def with_series_start(event), do: [event] |> with_series_start() |> hd()

  defp series_starts(integration_id, events) do
    integration_id
    |> SeriesRuleQueries.list_by_master(master_ids(events))
    |> Enum.map(fn {master_id, row} -> {{integration_id, master_id}, row.master_start} end)
  end

  @doc """
  `forget_orphans/1` for every integration, after a prune of the cache that
  spans them all.
  """
  @spec forget_all_orphans() :: :ok
  def forget_all_orphans do
    SeriesRuleQueries.delete_all_orphans()
    :ok
  end

  @doc "The distinct masters `calendar_events` name."
  @spec master_ids([map()]) :: [String.t()]
  def master_ids(calendar_events) do
    calendar_events
    |> Enum.map(&Map.get(&1, :recurring_event_id))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end
end
