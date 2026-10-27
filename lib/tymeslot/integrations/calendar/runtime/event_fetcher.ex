defmodule Tymeslot.Integrations.Calendar.Runtime.EventFetcher do
  @moduledoc """
  Reads a user's events from their connected calendar providers.

  Responsibilities:
  - Range fetches with request coalescing
  - Event filtering and deduplication

  Named a fetcher rather than a queries module because it performs no data
  access of its own: this is provider HTTP fan-out, metrics, and the
  fail-closed availability gate, on the live booking path. The `*_queries.ex`
  suffix would have exempted the whole file from `CredoChecks.RepoCallBoundary`
  for an exemption it never needed.
  """

  require Logger
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Integrations.Calendar.CalDAV.Base
  alias Tymeslot.Integrations.Calendar.Runtime.ClientManager
  alias Tymeslot.Integrations.Calendar.Runtime.EventsRead
  alias Tymeslot.Integrations.Calendar.Runtime.RequestCoalescer
  alias Tymeslot.Integrations.Calendar.Shared.FetchAggregate
  alias Tymeslot.Integrations.Calendar.Shared.FetchAggregate.Outcome

  @type user_id :: pos_integer()

  @doc """
  Gets fresh events for a date range.
  Uses request coalescing to prevent duplicate API calls when multiple
  requests for the same date range occur simultaneously.
  """
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
    {all_clients, unreadable_ids} = ClientManager.availability_sources(user_id)

    # Fetch events from each calendar in parallel. Unlinked and individually
    # timed out via `async_stream_nolink/on_timeout: :kill_task` rather than
    # `async/await_many`, so one slow calendar can't discard every other
    # calendar's already-fetched result — it now surfaces as a normal failed
    # entry that `resolve_availability_fetch/3` classifies, instead of the
    # whole coalesced fetch dying with `{:error, :timeout}`.
    #
    # Stream over indices, not over the clients themselves. A crashing task
    # makes OTP log a termination report containing the task function's
    # arguments verbatim, and a client carries the integration's decrypted
    # CalDAV password: streaming the clients directly put plaintext
    # credentials into the shipped logs every time a fetch raised. The
    # closure's captured environment is not part of that report, so resolving
    # the client inside the task keeps the credential out of it while leaving
    # the crash, the alert and the per-client isolation exactly as they were.
    clients_by_index =
      all_clients |> Enum.with_index() |> Map.new(fn {client, index} -> {index, client} end)

    results =
      Tymeslot.TaskSupervisor
      |> Tasks.async_stream_nolink(
        0..(length(all_clients) - 1)//1,
        fn index ->
          clients_by_index
          |> Map.fetch!(index)
          |> fetch_events_for_client_in_range(start_datetime, end_datetime)
        end,
        timeout: Base.task_await_timeout_ms(),
        on_timeout: :kill_task
      )
      |> unwrap_async_results()

    resolve_availability_fetch(results, unreadable_ids, user_id)
  end

  # This is the availability path, so anything less than a complete picture
  # fails closed: offering slots built only from the calendars that happened to
  # respond would silently hide conflicts sitting in the ones that didn't, and
  # a partial `{:ok, _}` is indistinguishable from a complete one. The actual
  # "an unread calendar is not an empty calendar" policy lives once in
  # `FetchAggregate`; this function only classifies raw results and logs the
  # outcome for this call site. An integration whose credentials no longer
  # decrypt was never fetched, and counts as a calendar that could not be read.
  defp resolve_availability_fetch(results, unreadable_ids, user_id) do
    unreadable =
      Enum.map(unreadable_ids, &{:error, :credentials_undecryptable, {:integration, &1}})

    client_count = length(results) + length(unreadable)

    (results ++ unreadable)
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
