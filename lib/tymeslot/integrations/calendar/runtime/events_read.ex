defmodule Tymeslot.Integrations.Calendar.EventsRead do
  @moduledoc """
  Read-path calendar operations (range and list-in-range) extracted from runtime operations.
  """

  require Logger
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Calendar.CalDAV.Base
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.Providers.ProviderAdapter

  @doc """
  Lists events within a date range from all configured calendars.
  Uses server-side filtering to exclude events outside the range.
  Fetches from all calendars in parallel for better performance.

  DEPRECATED: Prefer get_events_for_range_fresh/3 in Operations when possible.
  """
  @spec list_events_in_range(DateTime.t() | Date.t(), DateTime.t() | Date.t(), (-> list(map()))) ::
          {:ok, list(map())} | {:error, term()}
  def list_events_in_range(start_date, end_date, clients_fun \\ &Operations.clients/0) do
    Logger.info("Listing calendar events in range from all calendars",
      start_date: start_date,
      end_date: end_date
    )

    start_utc = ensure_utc(start_date)
    end_utc = ensure_utc(end_date)

    all_clients = clients_fun.()
    Logger.info("Fetching from #{length(all_clients)} calendar(s) in parallel")

    tasks =
      Enum.map(all_clients, fn client ->
        Task.async(fn -> fetch_events_with_fallback(client, start_utc, end_utc) end)
      end)

    results = Task.await_many(tasks, Base.task_await_timeout_ms())

    all_events =
      results
      |> Enum.filter(fn
        {:ok, _, _} -> true
        _ -> false
      end)
      |> Enum.flat_map(fn {:ok, events, _path} -> events end)
      |> Enum.uniq_by(& &1.uid)

    Logger.info("Total events found across all calendars: #{length(all_events)}")
    {:ok, all_events}
  end

  @doc """
  Fetches events for the given client with a fallback to full list filtering when needed.
  """
  @spec fetch_events_with_fallback(map(), DateTime.t(), DateTime.t()) ::
          {:ok, list(map()), String.t()} | {:error, term(), String.t()}
  def fetch_events_with_fallback(client, start_utc, end_utc) do
    case ProviderAdapter.get_events(client, start_utc, end_utc) do
      {:ok, events} ->
        wrap_events_result(client, {:ok, events})

      error ->
        Logger.warning(
          "Failed to fetch from calendar #{get_calendar_path(client)}, trying fallback"
        )

        case fallback_list_events_for_client(client, start_utc, end_utc, error) do
          {:ok, events} -> wrap_events_result(client, {:ok, events})
          error -> wrap_events_result(client, error, :error)
        end
    end
  end

  defp fallback_list_events_for_client(client, start_utc, end_utc, _original_error) do
    case ProviderAdapter.get_events(client) do
      {:ok, all_events} ->
        filtered =
          Enum.filter(all_events, fn event ->
            start_time = Map.get(event, :start_time)
            end_time = Map.get(event, :end_time)

            start_time && end_time &&
              DateTime.compare(start_time, end_utc) == :lt &&
              DateTime.compare(end_time, start_utc) == :gt
          end)

        Logger.info(
          "Fallback filtering for #{get_calendar_path(client)}: #{length(filtered)} events from #{length(all_events)} total"
        )

        {:ok, filtered}

      error ->
        Logger.error(
          "Fallback also failed for calendar #{get_calendar_path(client)}: #{Redactor.redact(error)}"
        )

        error
    end
  end

  @doc """
  Fetches events without a time range for the given client.
  """
  @spec fetch_events_without_range(map()) ::
          {:ok, list(map()), String.t()} | {:error, term(), String.t()}
  def fetch_events_without_range(client) do
    case ProviderAdapter.get_events(client) do
      {:ok, events} ->
        wrap_events_result(client, {:ok, events})

      error ->
        wrap_events_result(client, error, :error)
    end
  end

  defp ensure_utc(%DateTime{time_zone: "Etc/UTC"} = dt), do: dt

  defp ensure_utc(%DateTime{} = dt) do
    case DateTime.shift_zone(dt, "Etc/UTC") do
      {:ok, utc_dt} -> utc_dt
      _ -> dt
    end
  end

  defp ensure_utc(%Date{} = d) do
    DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
  end

  defp wrap_events_result(client, result, log_level \\ nil)

  defp wrap_events_result(client, {:ok, events}, _log_level) do
    Logger.debug("Calendar #{get_calendar_path(client)} returned #{length(events)} events")
    {:ok, events, get_calendar_path(client)}
  end

  defp wrap_events_result(client, {:error, error}, _log_level) do
    path = get_calendar_path(client)
    Logger.error("Failed to fetch from calendar #{path}: #{Redactor.redact(error)}")
    {:error, error, path}
  end

  defp get_calendar_path(client) do
    case client do
      %{client: %{calendar_path: path}} -> path
      %{calendar_path: path} -> path
      _ -> "unknown"
    end
  end
end
