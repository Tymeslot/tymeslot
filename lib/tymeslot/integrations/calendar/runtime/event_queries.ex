defmodule Tymeslot.Integrations.Calendar.Runtime.EventQueries do
  @moduledoc """
  Calendar event query operations (list and range queries).

  Responsibilities:
  - List events across all calendars
  - Range queries with request coalescing
  - Event filtering and deduplication
  """

  require Logger
  alias Tymeslot.Infrastructure.Metrics
  alias Tymeslot.Integrations.Calendar.CalDAV.Base
  alias Tymeslot.Integrations.Calendar.EventsRead
  alias Tymeslot.Integrations.Calendar.RequestCoalescer
  alias Tymeslot.Integrations.Calendar.Runtime.ClientManager
  alias Tymeslot.Integrations.Calendar.Shared.FetchAggregate
  alias Tymeslot.Integrations.Calendar.Shared.FetchAggregate.Outcome

  @type user_id :: pos_integer()

  @doc """
  Lists all events from all configured calendars.
  Fetches from all calendars in parallel for better performance.

  Reachable from the availability path (`Events.get_calendar_events/3` falls
  back here when the organiser's profile can't be loaded), so it shares
  `fetch_events_from_providers/3`'s fail-closed policy via
  `resolve_availability_fetch/3`: a calendar we failed to read from must
  never be silently treated as an empty diary.
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
            Tymeslot.TaskSupervisor
            |> Task.Supervisor.async_stream_nolink(all_clients, &fetch_events_from_client/1,
              timeout: 45_000,
              on_timeout: :kill_task
            )
            |> unwrap_async_results()

          resolve_availability_fetch(results, user_id, length(all_clients))
        end
      )
    end
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

  # --- Private Implementation ---

  # Private function that does the actual fetching for range queries
  defp fetch_events_from_providers(user_id, start_date, end_date) do
    Logger.info("Fetching fresh events for range", start_date: start_date, end_date: end_date)

    # Convert to DateTime for provider adapters (pass through if already DateTime)
    start_datetime = to_utc_datetime(start_date, ~T[00:00:00])
    end_datetime = to_utc_datetime(end_date, ~T[23:59:59])

    # Fetch events from all configured calendars
    all_clients = ClientManager.clients(user_id)

    # Fetch events from each calendar in parallel. Unlinked and individually
    # timed out via `async_stream_nolink/on_timeout: :kill_task` rather than
    # `async/await_many`, so one slow calendar can't discard every other
    # calendar's already-fetched result — it now surfaces as a normal failed
    # entry that `resolve_availability_fetch/3` classifies, instead of the
    # whole coalesced fetch dying with `{:error, :timeout}`.
    results =
      Tymeslot.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        all_clients,
        fn client -> fetch_events_for_client_in_range(client, start_datetime, end_datetime) end,
        timeout: Base.task_await_timeout_ms(),
        on_timeout: :kill_task
      )
      |> unwrap_async_results()

    resolve_availability_fetch(results, user_id, length(all_clients))
  end

  # This is the availability path, so anything less than a complete picture
  # fails closed: offering slots built only from the calendars that happened to
  # respond would silently hide conflicts sitting in the ones that didn't, and
  # a partial `{:ok, _}` is indistinguishable from a complete one. The actual
  # "an unread calendar is not an empty calendar" policy lives once in
  # `FetchAggregate`; this function only classifies raw results and logs the
  # outcome for this call site.
  defp resolve_availability_fetch(results, user_id, client_count) do
    results
    |> FetchAggregate.collect(&classify_fetch_result/1, user_id: user_id)
    |> FetchAggregate.require_complete()
    |> log_and_dedupe_availability(user_id, client_count)
  end

  # `fetch_events_from_client/1` fails with the 3-tuple `{:error, reason, path}`
  # (see `EventsRead.wrap_events_result/3`); a killed/crashed task instead
  # surfaces as the 2-tuple `{:error, {:task_exit, reason}}` from
  # `unwrap_async_results/1`. Both must be classified or a failed fetch raises
  # here instead of degrading, defeating the fail-closed handling below.
  #
  # A Google/Outlook client whose own multi-calendar fetch (MultiCalendarFetch)
  # hard-failed on at least one selected calendar surfaces its `Outcome` as
  # `reason` here rather than a flattened atom; classifying it as `:aggregate`
  # merges its events/attempted/succeeded/failed straight into this level's
  # `Outcome` (via `FetchAggregate.collect/3`) instead of counting one
  # integration's several calendars as a single opaque source.
  defp classify_fetch_result({:ok, events, _path}), do: {:ok, events}

  defp classify_fetch_result({:error, %Outcome{} = outcome, _path}), do: {:aggregate, outcome}

  defp classify_fetch_result({:error, reason, path}), do: {:error, path, reason}
  defp classify_fetch_result({:error, reason}), do: {:error, :unknown, reason}

  defp log_and_dedupe_availability({:ok, events}, _user_id, _client_count) do
    all_events = Enum.uniq_by(events, &{&1.uid, &1.start_time})

    Logger.info("Total fresh events found across all calendars", event_count: length(all_events))

    {:ok, all_events}
  end

  defp log_and_dedupe_availability(
         {:error, :all_calendars_unavailable} = error,
         user_id,
         client_count
       ) do
    Logger.warning("All calendar fetches failed, cannot determine availability",
      user_id: user_id,
      client_count: client_count
    )

    error
  end

  defp log_and_dedupe_availability(
         {:error, :some_calendars_unavailable} = error,
         user_id,
         client_count
       ) do
    Logger.warning("Some calendar fetches failed, cannot safely determine availability",
      user_id: user_id,
      client_count: client_count
    )

    error
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

  defp to_utc_datetime(%DateTime{} = dt, _default_time), do: dt

  defp to_utc_datetime(%Date{} = date, default_time),
    do: DateTime.new!(date, default_time, "Etc/UTC")
end
