defmodule Tymeslot.Integrations.Calendar.Runtime.EventsRead do
  @moduledoc """
  Read-path calendar operations (per-client range fetch with fallback,
  extracted from runtime operations).
  """

  require Logger
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Calendar.ICalNormaliser
  alias Tymeslot.Integrations.Calendar.Providers.ProviderAdapter
  alias Tymeslot.Integrations.Calendar.Shared.FetchAggregate.Outcome

  # The furthest any timezone sits ahead of and behind UTC, for reading an
  # all-day event's dates without knowing the owner's timezone.
  @earliest_offset_seconds -14 * 3600
  @latest_offset_seconds 12 * 3600

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

      {:error, %Outcome{failed: failed}} = error when failed != [] ->
        # This is a retry-skip optimisation, not the aggregation policy that
        # `FetchAggregate` centralises below: the primary fetch already ran
        # the full multi-calendar fetch (MultiCalendarFetch) and at least one
        # selected calendar hard-failed; the fallback below re-runs that same
        # multi-calendar fetch over a 13x wider range (30d..365d vs. the
        # narrow range here), so it cannot succeed where the primary just
        # failed for this reason. Retrying it anyway would double the timeout
        # risk and provider quota use exactly when the provider is already
        # degraded. Deciding this from `outcome.failed` (rather than a
        # provider-specific error atom) is what lets `MultiCalendarFetch`
        # report the real per-calendar failures instead of flattening them.
        Logger.warning("Primary fetch reported unavailable calendars, skipping fallback",
          calendar_path: get_calendar_path(client),
          failed_count: length(failed)
        )

        wrap_events_result(client, error, :error)

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

  # The fallback reads `ProviderAdapter.default_window/0`, widened to take in
  # the whole range asked for, and filters the answer to that range. A read
  # of the default window alone answered a range reaching outside it as
  # empty, and an empty answer offers slots over the host's real conflicts.
  defp fallback_list_events_for_client(client, start_utc, end_utc, _original_error) do
    {window_start, window_end} = ProviderAdapter.default_window()

    window =
      {Enum.min([start_utc, window_start], DateTime), Enum.max([end_utc, window_end], DateTime)}

    fallback_read(client, start_utc, end_utc, window)
  end

  defp fallback_read(client, start_utc, end_utc, {window_start, window_end}) do
    case ProviderAdapter.get_events(client, window_start, window_end) do
      {:ok, all_events} ->
        # Normalise before filtering, exactly as the primary path does. Google
        # and Outlook return raw string-keyed API maps here, on which every
        # `event[:start_time]` below is nil: without this the fallback filters
        # every event out and reports `{:ok, []}`, which the availability path
        # cannot distinguish from a genuinely empty calendar and so offers
        # slots straight over the host's real conflicts.
        normalized = normalize_events(client, all_events)

        # Expand recurring events first so their occurrences can be range-filtered
        expanded = expand_recurring_events(normalized, start_utc, end_utc)

        filtered = Enum.filter(expanded, &overlaps_range?(&1, start_utc, end_utc))

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

  # Every provider maps its `list_events/2` answer into atom-keyed plain maps,
  # so downstream code can always read :uid, :start_time, etc.
  defp normalize_events(client, events), do: client.provider_module.convert_events(events)

  # Expands recurring events (those with a recurrence_rule) into individual
  # occurrences within the requested date range, through the same expansion
  # the sync uses: in the series' own zone, so a series keeps its wall-clock
  # time across a DST change, and without the occurrences its `RECURRENCE-ID`
  # overrides have moved. Google and Outlook arrive already expanded and carry
  # no rule, so their events pass through unchanged.
  defp expand_recurring_events(events, range_start, range_end),
    do: ICalNormaliser.expand_occurrences(events, range_start, range_end)

  # All-day events carry bare `%Date{}` values the whole way down this path:
  # the iCal parser emits them for DATE-form DTSTART/DTEND, `RecurrenceExpander`
  # preserves them for all-day occurrences, and `Availability.Events` matches on
  # them downstream. So the range check has to coerce before comparing rather
  # than assume `%DateTime{}`, and it must leave the event itself untouched.
  #
  # The owner's timezone is not known here, and an all-day event blocks the
  # owner's local day (`Availability.Events.to_interval/2`), so a date is read
  # as widely as any timezone could place it: from the moment its day begins
  # anywhere to the moment its end date begins everywhere. That only ever keeps
  # an event the downstream conversion then places exactly.
  defp overlaps_range?(event, start_utc, end_utc) do
    case {earliest(Map.get(event, :start_time)), latest(Map.get(event, :end_time))} do
      {%DateTime{} = starts_at, %DateTime{} = ends_at} ->
        DateTime.compare(starts_at, end_utc) == :lt and
          DateTime.compare(ends_at, start_utc) == :gt

      _incomplete ->
        false
    end
  end

  # Total by design: this runs over unvalidated provider output, so anything
  # that is neither a `Date` nor a `DateTime` (a missing time, a shape a new
  # provider invents) drops the event from the range rather than raising and
  # killing the whole fetch.
  defp earliest(%Date{} = date), do: utc_midnight(date, @earliest_offset_seconds)
  defp earliest(other), do: as_datetime(other)

  defp latest(%Date{} = date), do: utc_midnight(date, @latest_offset_seconds)
  defp latest(other), do: as_datetime(other)

  defp as_datetime(%DateTime{} = datetime), do: datetime
  defp as_datetime(_other), do: nil

  defp utc_midnight(date, offset_seconds),
    do: date |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.add(offset_seconds, :second)

  defp wrap_events_result(client, result, _log_level \\ nil)

  defp wrap_events_result(client, {:ok, events}, _log_level) do
    Logger.debug("Calendar returned events",
      calendar_path: get_calendar_path(client),
      event_count: length(events)
    )

    {:ok, events, get_calendar_path(client)}
  end

  # %Outcome{} carries the full events list of every calendar that
  # succeeded, so it must never be handed to a logger whole (see the
  # generic clause below, which would otherwise inspect it). Log only the
  # operational summary: counts and which calendars failed and why.
  defp wrap_events_result(client, {:error, %Outcome{} = outcome}, _log_level) do
    path = get_calendar_path(client)

    Logger.error("Failed to fetch from calendar",
      calendar_path: path,
      attempted: outcome.attempted,
      succeeded: outcome.succeeded,
      failed:
        Enum.map(outcome.failed, fn %{source: source, reason: reason} ->
          %{source: source, reason: Redactor.redact_and_truncate(reason)}
        end)
    )

    {:error, outcome, path}
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
