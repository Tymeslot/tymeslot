defmodule Tymeslot.Integrations.Calendar.Outlook.OccurrenceStubs do
  @moduledoc """
  Completes the occurrences a `calendarView/delta` read gives as stubs.

  Graph's delta lists an unchanged occurrence of a series with its timing
  and identity only (`id`, `type`, `start`, `end`, `seriesMasterId`): no
  title, no `isAllDay`, no free/busy. Normalised as it is, an occurrence of
  an all-day series reads as a timed, untitled event from midnight UTC to
  midnight UTC, and one of a series shown as free blocks the time.

  Everything else an occurrence shows is its series' master's, so a stub
  takes those fields from it: from the master the same read listed, which
  a delta does whenever the series changed, or else from a read of the
  master. An occurrence edited on its own is an `exception`, listed in
  full, and is left alone.

  ## A master that cannot be read

  Reads of masters share the integration's `:series_rule_read` budget with
  the series rules (`SeriesRules.charged_read/2`), and the rules take what
  they found rather than reading the masters again
  (`SeriesRules.refresh/4`'s `already_read:`). The first read that fails
  (throttled, the budget spent, the breaker open) ends the reads for the
  run, and the stubs left over are cached as they came.

  A delta lists an unchanged occurrence once, so such a stub would stay
  wrong until its series changed. It is recoverable: the cached row keeps
  the stub as Graph gave it (`provider_metadata`), still without the fields
  a completed one carries, so the next delta sweep finds it
  (`unresolved/2`) and tries again (`complete/3`).
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Outlook.SeriesMaster
  alias Tymeslot.Integrations.Calendar.ProviderCalendarSeriesQueries
  alias Tymeslot.Integrations.Calendar.SeriesRules

  # What a stub takes from its master: the fields `EventNormaliser` reads,
  # apart from the ones that are the occurrence's own (identity, timing).
  @from_master ~w(subject body location sensitivity showAs isCancelled responseStatus organizer
                  attendees reminderMinutesBeforeStart isAllDay originalStartTimeZone)

  @typedoc """
  What each master read made this run found, as `SeriesRules.refresh/4`
  takes it; `{:stop, reason}` for the one that ended the reads.
  """
  @type reads :: %{String.t() => {:ok, SeriesMaster.found()} | :gone | {:stop, term()}}

  @doc "The fields a stub takes from its master, for the master read to select."
  @spec master_fields() :: [String.t()]
  def master_fields, do: @from_master

  @doc """
  `raw_events` with every stub completed from its master, in order, then
  each of `retry` (stubs cached earlier, from `unresolved/2`) that could be
  completed this time; the ones that still cannot are left out, as they are
  cached already. With what each master read found, for the series rules.
  """
  @spec complete([map()], CalendarIntegrationSchema.t(), [map()]) :: {[map()], reads()}
  def complete(raw_events, %CalendarIntegrationSchema{} = integration, retry \\ []) do
    case Enum.filter(raw_events, &stub?/1) ++ retry do
      [] ->
        {raw_events, %{}}

      stubs ->
        {masters, reads} = masters(raw_events, stubs, integration)

        retried =
          retry
          |> Enum.map(&complete_one(&1, masters))
          |> Enum.reject(&stub?/1)

        {Enum.map(raw_events, &complete_one(&1, masters)) ++ retried, reads}
    end
  end

  @doc """
  The stubs the integration's cache holds as they came, never completed,
  as Graph listed them: all but the ones with an id in `except` (the events
  a read about to be applied lists or removes, which supersede them).
  """
  @spec unresolved(CalendarIntegrationSchema.t(), [String.t()]) :: [map()]
  def unresolved(%CalendarIntegrationSchema{id: integration_id}, except) do
    integration_id
    |> ProviderCalendarSeriesQueries.list_unresolved_outlook_stubs(except)
    |> Enum.filter(&stub?/1)
  end

  # A stub is an occurrence without the fields every listed event carries.
  defp stub?(%{"type" => "occurrence", "seriesMasterId" => master_id} = raw)
       when is_binary(master_id),
       do: not is_map_key(raw, "isAllDay")

  defp stub?(_raw), do: false

  defp complete_one(raw, masters) do
    with true <- stub?(raw),
         {:ok, master} <- Map.fetch(masters, raw["seriesMasterId"]) do
      master |> Map.take(@from_master) |> Map.merge(raw)
    else
      _other -> raw
    end
  end

  # The masters the read listed, and a read of each other one a stub names
  # until a read fails (every later one would fail alike, and spend the
  # budget); with what each read found.
  defp masters(raw_events, stubs, integration) do
    listed =
      for %{"type" => "seriesMaster", "id" => id} = raw <- raw_events, into: %{}, do: {id, raw}

    stubs
    |> Enum.map(& &1["seriesMasterId"])
    |> Enum.uniq()
    |> Enum.reject(&Map.has_key?(listed, &1))
    |> Enum.reduce_while({listed, %{}}, fn master_id, {masters, reads} ->
      case read_master(integration, master_id) do
        {:ok, master} ->
          {:cont,
           {Map.put(masters, master_id, master),
            Map.put(reads, master_id, {:ok, SeriesMaster.found(master)})}}

        :gone ->
          log_unread(integration, :gone)
          {:cont, {masters, Map.put(reads, master_id, :gone)}}

        {:stop, reason} ->
          log_unread(integration, reason)
          {:halt, {masters, Map.put(reads, master_id, {:stop, reason})}}
      end
    end)
  end

  defp log_unread(integration, reason) do
    Logger.warning("Could not read an Outlook series master to complete its occurrences",
      calendar_integration_id: integration.id,
      error: LogFormat.reason(reason)
    )
  end

  defp read_master(integration, master_id) do
    SeriesRules.charged_read(integration.id, fn -> SeriesMaster.fetch(integration, master_id) end)
  end
end
