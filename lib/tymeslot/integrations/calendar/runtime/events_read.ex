defmodule Tymeslot.Integrations.Calendar.EventsRead do
  @moduledoc """
  Read-path calendar operations (range and list-in-range) extracted from runtime operations.
  """

  require Logger
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Calendar.CalDAV.Base
  alias Tymeslot.Integrations.Calendar.Providers.ProviderAdapter
  alias Tymeslot.Integrations.Calendar.RecurrenceExpander
  alias Tymeslot.Integrations.Calendar.Runtime.ClientManager

  @doc """
  Lists events within a date range from all configured calendars.
  Uses server-side filtering to exclude events outside the range.
  Fetches from all calendars in parallel for better performance.

  DEPRECATED: Prefer get_events_for_range_fresh/3 in EventQueries when possible.
  """
  @spec list_events_in_range(DateTime.t() | Date.t(), DateTime.t() | Date.t(), (-> list(map()))) ::
          {:ok, list(map())} | {:error, term()}
  def list_events_in_range(start_date, end_date, clients_fun \\ &ClientManager.clients/0) do
    Logger.info("Listing calendar events in range from all calendars",
      start_date: start_date,
      end_date: end_date
    )

    case {ensure_utc(start_date), ensure_utc(end_date)} do
      {{:ok, start_utc}, {:ok, end_utc}} ->
        all_clients = clients_fun.()
        Logger.info("Fetching from calendars in parallel", calendar_count: length(all_clients))

        tasks =
          Enum.map(all_clients, fn client ->
            Task.Supervisor.async(Tymeslot.TaskSupervisor, fn ->
              fetch_events_with_fallback(client, start_utc, end_utc)
            end)
          end)

        results = Task.await_many(tasks, Base.task_await_timeout_ms())

        all_events =
          results
          |> Enum.filter(fn
            {:ok, _events, _path} -> true
            _result -> false
          end)
          |> Enum.flat_map(fn {:ok, events, _path} -> events end)
          |> Enum.uniq_by(&{&1.uid, &1.start_time})

        Logger.info("Total events found across all calendars", event_count: length(all_events))
        {:ok, all_events}

      _result ->
        {:error, :timezone_error}
    end
  end

  @doc """
  Fetches events for the given client with a fallback to full list filtering when needed.
  """
  @spec fetch_events_with_fallback(ProviderAdapter.adapter_client(), DateTime.t(), DateTime.t()) ::
          {:ok, list(map()), String.t()} | {:error, term(), String.t()}
  def fetch_events_with_fallback(client, start_utc, end_utc) do
    case ProviderAdapter.get_events(client, start_utc, end_utc) do
      {:ok, events} ->
        normalized = normalize_events(client, events)
        expanded = expand_recurring_events(normalized, start_utc, end_utc)

        wrap_events_result(client, {:ok, expanded})

      error ->
        Logger.warning("Failed to fetch from calendar, trying fallback",
          calendar_path: get_calendar_path(client)
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
        # Expand recurring events first so their occurrences can be range-filtered
        expanded = expand_recurring_events(all_events, start_utc, end_utc)

        filtered =
          Enum.filter(expanded, fn event ->
            start_time = Map.get(event, :start_time)
            end_time = Map.get(event, :end_time)

            start_time && end_time &&
              DateTime.compare(start_time, end_utc) == :lt &&
              DateTime.compare(end_time, start_utc) == :gt
          end)

        Logger.info("Fallback filtering applied",
          calendar_path: get_calendar_path(client),
          filtered_count: length(filtered),
          total_count: length(expanded)
        )

        {:ok, filtered}

      error ->
        Logger.error("Fallback also failed for calendar",
          calendar_path: get_calendar_path(client),
          error: Redactor.redact(error)
        )

        error
    end
  end

  @doc """
  Fetches events without a time range for the given client.
  """
  @spec fetch_events_without_range(ProviderAdapter.adapter_client()) ::
          {:ok, list(map()), String.t()} | {:error, term(), String.t()}
  def fetch_events_without_range(client) do
    case ProviderAdapter.get_events(client) do
      {:ok, events} ->
        now = DateTime.utc_now()
        range_start = DateTime.add(now, -30, :day)
        range_end = DateTime.add(now, 365, :day)

        normalized = normalize_events(client, events)
        expanded = expand_recurring_events(normalized, range_start, range_end)

        wrap_events_result(client, {:ok, expanded})

      error ->
        wrap_events_result(client, error, :error)
    end
  end

  # OAuth providers (Google, Outlook) return raw string-keyed API maps. CalDAV providers
  # already return atom-keyed maps. Apply convert_events when the provider exposes it so
  # downstream code can always access :uid, :start_time, etc. via atom keys.
  defp normalize_events(client, events) do
    if function_exported?(client.provider_module, :convert_events, 1) do
      client.provider_module.convert_events(events)
    else
      events
    end
  end

  # Expands recurring events (those with a recurrence_rule) into individual
  # occurrences within the requested date range. Non-recurring events pass
  # through unchanged. Each occurrence replaces start_time/end_time with the
  # concrete occurrence times so downstream availability checking sees them
  # as distinct events.
  defp expand_recurring_events(events, range_start, range_end) do
    Enum.flat_map(events, &expand_event(&1, range_start, range_end))
  end

  defp expand_event(event, range_start, range_end) do
    rrule = event[:rrule] || event[:recurrence_rule]

    if rrule && rrule != "" do
      expander_event = %{
        start_time: event[:dtstart] || event[:start_time],
        end_time: event[:dtend] || event[:end_time],
        recurrence_rule: rrule
      }

      exdates = parse_exdates(event[:exdate] || event[:exdates] || [])

      expander_event
      |> RecurrenceExpander.expand(range_start, range_end, exdates: exdates)
      |> Enum.map(fn occurrence ->
        event
        |> Map.put(:start_time, occurrence.start_time)
        |> Map.put(:end_time, occurrence.end_time)
      end)
    else
      [event]
    end
  end

  defp parse_exdates(exdates) when is_list(exdates), do: exdates
  defp parse_exdates(_other), do: []

  defp ensure_utc(%DateTime{time_zone: "Etc/UTC"} = dt), do: {:ok, dt}

  defp ensure_utc(%DateTime{} = dt) do
    case DateTime.shift_zone(dt, "Etc/UTC") do
      {:ok, utc_dt} -> {:ok, utc_dt}
      {:error, _reason} -> {:error, :timezone_error}
    end
  end

  defp ensure_utc(%Date{} = d) do
    {:ok, DateTime.new!(d, ~T[00:00:00], "Etc/UTC")}
  end

  defp wrap_events_result(client, result, _log_level \\ nil)

  defp wrap_events_result(client, {:ok, events}, _log_level) do
    Logger.debug("Calendar returned events",
      calendar_path: get_calendar_path(client),
      event_count: length(events)
    )

    {:ok, events, get_calendar_path(client)}
  end

  defp wrap_events_result(client, {:error, error}, _log_level) do
    path = get_calendar_path(client)

    Logger.error("Failed to fetch from calendar",
      calendar_path: path,
      error: Redactor.redact(error)
    )

    {:error, error, path}
  end

  defp wrap_events_result(client, {:error, type, reason}, _log_level) do
    path = get_calendar_path(client)

    Logger.error("Failed to fetch from calendar",
      calendar_path: path,
      error_type: type,
      error: Redactor.redact(reason)
    )

    {:error, {type, reason}, path}
  end

  defp get_calendar_path(client) do
    case client do
      %{client: %{calendar_path: path}} -> path
      _other -> "unknown"
    end
  end
end
