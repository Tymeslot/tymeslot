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
  full, and is left alone, as is a stub whose master cannot be read.
  """

  require Logger

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema

  # What a stub takes from its master: the fields `EventNormaliser` reads,
  # apart from the ones that are the occurrence's own (identity, timing).
  @from_master ~w(subject body location sensitivity showAs isCancelled responseStatus organizer
                  attendees reminderMinutesBeforeStart isAllDay originalStartTimeZone)

  @doc "The fields a stub takes from its master, for the master read to select."
  @spec master_fields() :: [String.t()]
  def master_fields, do: @from_master

  @doc """
  `raw_events` with every stub completed from its master, in order.
  """
  @spec complete([map()], CalendarIntegrationSchema.t()) :: [map()]
  def complete(raw_events, %CalendarIntegrationSchema{} = integration) do
    case Enum.filter(raw_events, &stub?/1) do
      [] ->
        raw_events

      stubs ->
        masters = masters(raw_events, stubs, integration)
        Enum.map(raw_events, &complete_one(&1, masters))
    end
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

  # The masters the read listed, and a read of each other one a stub names.
  defp masters(raw_events, stubs, integration) do
    listed =
      for %{"type" => "seriesMaster", "id" => id} = raw <- raw_events, into: %{}, do: {id, raw}

    stubs
    |> Enum.map(& &1["seriesMasterId"])
    |> Enum.uniq()
    |> Enum.reject(&Map.has_key?(listed, &1))
    |> Enum.reduce(listed, fn master_id, acc ->
      case read_master(integration, master_id) do
        {:ok, master} -> Map.put(acc, master_id, master)
        :error -> acc
      end
    end)
  end

  defp read_master(integration, master_id) do
    case Config.outlook_calendar_api_module().get_series_master(integration, master_id) do
      {:ok, %{} = master} ->
        {:ok, master}

      error ->
        Logger.warning("Could not read an Outlook series master to complete its occurrences",
          calendar_integration_id: integration.id,
          error: LogFormat.reason(error)
        )

        :error
    end
  end
end
