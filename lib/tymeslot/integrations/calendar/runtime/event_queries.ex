defmodule Tymeslot.Integrations.Calendar.Runtime.EventQueries do
  @moduledoc """
  Calendar event query operations (list, range, month queries).

  Responsibilities:
  - List events across all calendars
  - Range queries with request coalescing
  - Month queries with async fetching
  - Event filtering and deduplication
  """

  require Logger
  alias Tymeslot.Infrastructure.Metrics
  alias Tymeslot.Integrations.Calendar.CalDAV.Base
  alias Tymeslot.Integrations.Calendar.EventsRead
  alias Tymeslot.Integrations.Calendar.RequestCoalescer
  alias Tymeslot.Integrations.Calendar.Runtime.ClientManager

  @type user_id :: pos_integer()

  @doc """
  Lists all events from all configured calendars.
  Fetches from all calendars in parallel for better performance.
  """
  @spec list_events(user_id() | nil) :: {:ok, list(map())} | {:error, term()}
  def list_events(user_id \\ nil) do
    all_clients = ClientManager.clients(user_id)

    if all_clients == [] do
      {:ok, []}
    else
      Metrics.time_operation(
        :list_events,
        %{calendar_count: length(all_clients)},
        fn ->
          Logger.info("Listing all calendar events from all calendars")
          Logger.info("Fetching from calendars in parallel", calendar_count: length(all_clients))

          results =
            all_clients
            |> Task.async_stream(&fetch_events_from_client/1, timeout: 45_000)
            |> unwrap_async_results()

          {successful_results, failed_results} =
            Enum.split_with(results, &successful_result?/1)

          if failed_results != [] do
            Logger.warning("Some calendar fetches failed",
              user_id: user_id,
              failed_count: length(failed_results),
              errors: Enum.map(failed_results, fn {:error, reason} -> reason end)
            )
          end

          if Enum.empty?(successful_results) do
            {:error, :fetch_failed}
          else
            all_events =
              successful_results
              |> Enum.flat_map(&extract_events/1)
              |> Enum.uniq_by(& &1.uid)

            Logger.info("Total events found across all calendars",
              event_count: length(all_events)
            )

            {:ok, all_events}
          end
        end
      )
    end
  end

  @doc """
  Gets events for a month for display purposes.
  Uses request coalescing to prevent duplicate API calls.
  """
  @spec get_events_for_month(user_id(), integer(), integer(), String.t()) ::
          {:ok, list(map())} | {:error, term()}
  def get_events_for_month(user_id, year, month, timezone) do
    Metrics.time_operation(:get_events_for_month, %{year: year, month: month}, fn ->
      Logger.info("Getting events for month", year: year, month: month, timezone: timezone)

      {start_dt, end_dt} = month_utc_boundaries(year, month, timezone)
      get_events_for_range_fresh(user_id, start_dt, end_dt)
    end)
  end

  @doc """
  Gets fresh events for a date range.
  Uses request coalescing to prevent duplicate API calls when multiple
  requests for the same date range occur simultaneously.
  """
  @spec get_events_for_range_fresh(Date.t(), Date.t()) :: {:error, :user_id_required}
  def get_events_for_range_fresh(_start_date, _end_date) do
    # No implicit user context allowed anymore
    {:error, :user_id_required}
  end

  @spec get_events_for_range_fresh(user_id(), Date.t() | DateTime.t(), Date.t() | DateTime.t()) ::
          {:ok, list(map())} | {:error, term()}
  def get_events_for_range_fresh(user_id, start_date, end_date) when is_integer(user_id) do
    RequestCoalescer.coalesce(user_id, start_date, end_date, fn ->
      fetch_events_from_providers(user_id, start_date, end_date)
    end)
  end

  @doc """
  Lists events within a date range from all configured calendars.
  Uses server-side filtering to exclude events outside the range.
  Fetches from all calendars in parallel for better performance.

  DEPRECATED: Use get_events_for_range_fresh/3 instead.
  """
  @spec list_events_in_range(user_id() | nil, DateTime.t() | Date.t(), DateTime.t() | Date.t()) ::
          {:ok, list(map())} | {:error, term()}
  def list_events_in_range(user_id, start_date_or_dt, end_date_or_dt) do
    EventsRead.list_events_in_range(start_date_or_dt, end_date_or_dt, fn ->
      ClientManager.clients(user_id)
    end)
  end

  @doc false
  @spec month_utc_boundaries(integer(), 1..12, String.t()) :: {DateTime.t(), DateTime.t()}
  def month_utc_boundaries(year, month, timezone) do
    start_date = Date.new!(year, month, 1)
    end_date = Date.end_of_month(start_date)

    # Convert month boundaries in user's timezone to UTC so we don't miss events
    # near day boundaries (e.g. UTC+12 starts 12h before UTC midnight)
    start_dt =
      DateTime.shift_zone!(DateTime.new!(start_date, ~T[00:00:00], timezone), "Etc/UTC")

    end_dt = DateTime.shift_zone!(DateTime.new!(end_date, ~T[23:59:59], timezone), "Etc/UTC")

    {start_dt, end_dt}
  end

  # --- Private Implementation ---

  # Private function that does the actual fetching for range queries
  defp fetch_events_from_providers(user_id, start_date, end_date) do
    Logger.info("Fetching fresh events for range", start_date: start_date, end_date: end_date)

    # Convert to DateTime for provider adapters (pass through if already DateTime)
    start_datetime = to_utc_datetime(start_date, ~T[00:00:00])
    end_datetime = to_utc_datetime(end_date, ~T[23:59:59])

    # Fetch events from all configured calendars
    all_clients = ClientManager.clients(user_id)

    # Fetch events from each calendar in parallel
    tasks =
      Enum.map(all_clients, fn client ->
        Task.async(fn ->
          fetch_events_for_client_in_range(client, start_datetime, end_datetime)
        end)
      end)

    # Wait for all tasks to complete
    results = Task.await_many(tasks, Base.task_await_timeout_ms())

    successful = Enum.filter(results, &match?({:ok, _events, _path}, &1))

    if successful == [] do
      # All configured calendars failed (circuit open, network error, etc.). Return an error
      # rather than {:ok, []} — an empty list would make every slot look available, silently
      # hiding conflicts with external calendar entries.
      Logger.warning("All calendar fetches failed, cannot determine availability",
        user_id: user_id,
        client_count: length(all_clients)
      )

      {:error, :all_calendars_unavailable}
    else
      all_events =
        successful
        |> Enum.flat_map(fn {:ok, events, _path} -> events end)
        |> Enum.uniq_by(& &1.uid)

      Logger.info("Total fresh events found across all calendars",
        event_count: length(all_events)
      )

      {:ok, all_events}
    end
  end

  defp fetch_events_for_client_in_range(client, start_datetime, end_datetime) do
    EventsRead.fetch_events_with_fallback(client, start_datetime, end_datetime)
  end

  defp fetch_events_from_client(client) do
    EventsRead.fetch_events_without_range(client)
  end

  defp unwrap_async_results(stream) do
    Enum.map(stream, fn
      {:ok, res} -> res
      {:exit, reason} -> {:error, {:task_exit, reason}}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :unknown_task_result}
    end)
  end

  defp successful_result?({:ok, _events, _path}), do: true
  defp successful_result?(_result), do: false

  defp extract_events({:ok, events, _path}), do: events

  defp to_utc_datetime(%DateTime{} = dt, _default_time), do: dt

  defp to_utc_datetime(%Date{} = date, default_time),
    do: DateTime.new!(date, default_time, "Etc/UTC")
end
