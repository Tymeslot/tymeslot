defmodule Tymeslot.Integrations.Calendar.Google.SyncCycle do
  @moduledoc """
  One sync cycle of a Google Calendar integration: what a sync reads from
  Google and writes to the cache, with no knowledge of the job running it.

  The booking calendar is read as a delta from the stored sync token, or
  bootstrapped in full when there is none or Google expired it. The
  selected secondary calendars are read in full each run, over the sync
  window, as is the booking calendar when a sync was requested. The
  instances of every series the delta names are read in full too, since a
  delta need not cancel the old instances of a retimed series. Those
  listings carry no deletions, so once a run has read every calendar, the
  rows the listings no longer returned are swept
  (`Tymeslot.Integrations.Calendar.Google.CacheSweep`).
  """

  require Logger

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Defaults
  alias Tymeslot.Integrations.Calendar.Google.CacheSweep
  alias Tymeslot.Integrations.Calendar.Google.Provider, as: GoogleProvider
  alias Tymeslot.Integrations.Calendar.Google.SeriesMaster
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Integrations.Calendar.SeriesRules
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Integrations.Calendar.SyncBroadcast

  @failures [:unauthorized, :booking_calendar_missing, :not_a_calendar_user, :circuit_open]

  @typedoc """
  The failures a caller is expected to interpret: Google rejected the
  credentials, the booking calendar is gone, the account has no Google
  Calendar, the breaker is open, or a listing ran past the page limit.
  """
  @type failure ::
          :unauthorized
          | :booking_calendar_missing
          | :not_a_calendar_user
          | :circuit_open
          | {:too_many_pages, String.t()}

  @doc """
  Runs one sync cycle of the Google integration `integration`.

  Reads the booking calendar's delta from its sync token, or bootstraps it
  when the token is missing or expired; then, with `list_booking_calendar:
  true`, reads the booking calendar in full too, and reads each selected
  secondary calendar in full. Once every calendar has been read, the rows
  the listings no longer returned are swept.

  Returns `:ok`, or `{:error, reason}` where `reason` is one of the
  `t:failure/0` reasons the caller is expected to interpret, or any other
  term for a failure worth retrying.
  """
  @spec run(CalendarIntegrationSchema.t(), keyword()) :: :ok | {:error, failure() | term()}
  def run(%CalendarIntegrationSchema{} = integration, opts \\ []) do
    # `started_at` is taken before anything is read from Google: every row
    # this run writes is written after it, which is what lets `CacheSweep`
    # tell the rows a listing returned from the ones it no longer does.
    started_at = DateTime.utc_now(:microsecond)

    case Config.google_calendar_api_module().list_events_incremental(integration) do
      {:ok, %{events: events, next_sync_token: next_sync_token}} ->
        Logger.info("Incremental Google Calendar sync fetched events",
          calendar_integration_id: integration.id,
          event_count: length(events)
        )

        relist =
          if Keyword.get(opts, :list_booking_calendar, false),
            do: :calendar,
            else: {:series, events}

        process_incremental_sync(integration, events, next_sync_token, {started_at, relist})

      {:error, :gone, _message} ->
        Logger.warning(
          "Google Calendar sync token expired; performing full bootstrap resync",
          calendar_integration_id: integration.id
        )

        bootstrap_integration(integration, started_at)

      {:error, :no_sync_token} ->
        Logger.info(
          "Google Calendar integration has no sync token; performing initial bootstrap",
          calendar_integration_id: integration.id
        )

        bootstrap_integration(integration, started_at)

      failure ->
        fetch_failure(integration, :delta, failure)
    end
  end

  # Unlike a delta, the bootstrap is a complete windowed listing of the
  # booking calendar, so it is swept like a secondary calendar's.
  defp bootstrap_integration(integration, started_at) do
    listed = {Defaults.booking_calendar_id(integration), Sync.window()}

    case Config.google_calendar_api_module().bootstrap_sync(integration) do
      {:ok, %{events: events, next_sync_token: next_sync_token}} ->
        Logger.info("Google Calendar bootstrap fetched events",
          calendar_integration_id: integration.id,
          event_count: length(events)
        )

        process_incremental_sync(integration, events, next_sync_token, {started_at, [listed]})

      failure ->
        fetch_failure(integration, :bootstrap, failure)
    end
  end

  # One classification for a failed read of the booking calendar, whether
  # the delta or the bootstrap failed: the reasons a caller acts on are
  # named, the client's three-element errors flattened, anything else kept
  # to be retried.
  defp fetch_failure(integration, phase, failure) do
    case classify(failure) do
      {:error, reason} = error when reason in @failures ->
        Logger.warning("Google Calendar read failed",
          calendar_integration_id: integration.id,
          phase: phase,
          reason: reason
        )

        error

      {:error, {:too_many_pages, message}} = error ->
        Logger.error("Google Calendar read exceeded pagination limit",
          calendar_integration_id: integration.id,
          phase: phase,
          error: message
        )

        error

      {:error, reason} = error ->
        Logger.error("Google Calendar read failed",
          calendar_integration_id: integration.id,
          phase: phase,
          error: LogFormat.reason(reason)
        )

        error
    end
  end

  defp classify({:error, :unauthorized, _message}), do: {:error, :unauthorized}
  defp classify({:error, :not_found, _message}), do: {:error, :booking_calendar_missing}
  defp classify({:error, :not_a_calendar_user, _message}), do: {:error, :not_a_calendar_user}
  defp classify({:error, :circuit_open}), do: {:error, :circuit_open}
  defp classify({:error, :too_many_pages, message}), do: {:error, {:too_many_pages, message}}
  defp classify({:error, _type, reason}), do: {:error, reason}
  defp classify({:error, reason}), do: {:error, reason}

  # The sweep runs once every calendar has been read, and only when every
  # one was: a row a calendar's listing no longer returns may be one another
  # calendar of the integration now returns (an event moved between them,
  # its row still filed under the calendar it came from), and that listing
  # rewrites it, which spares it.
  #
  # `listed` is what the booking calendar's own read covered: the bootstrap's
  # complete listing, or for a delta what is read of it besides
  # (`relist_booking_calendar/2`).
  defp process_incremental_sync(integration, events, next_sync_token, {started_at, listed}) do
    # A listing (the bootstrap's) changed nothing; a delta did.
    with :ok <- safe_process_events(integration, events, nil, not is_list(listed)),
         :ok <- persist_sync_state(integration, next_sync_token),
         {:ok, booking_listed} <- relist_booking_calendar(integration, listed),
         {:ok, secondary_listed} <- sync_secondary_calendars(integration) do
      CacheSweep.sweep(integration, booking_listed ++ secondary_listed, started_at)
      SyncBroadcast.broadcast_sync_complete(integration.user_id, integration.id)
      :ok
    else
      {:error, reason} ->
        Logger.error("Google Calendar event processing failed; sync token NOT updated",
          calendar_integration_id: integration.id,
          error: LogFormat.reason(reason)
        )

        {:error, reason}

      other ->
        other
    end
  end

  defp relist_booking_calendar(_integration, listed) when is_list(listed), do: {:ok, listed}

  # A requested sync reads the booking calendar in full, as a secondary
  # calendar is read on every run.
  defp relist_booking_calendar(integration, :calendar) do
    {start_time, end_time} = window = Sync.window()
    calendar_id = Defaults.booking_calendar_id(integration)

    case sync_one_secondary_calendar(integration, calendar_id, start_time, end_time) do
      :listed -> {:ok, [{calendar_id, window}]}
      {:halt, value} -> value
      # Refused or missing: nothing is swept, and the delta has done its work.
      _skipped -> {:ok, []}
    end
  end

  # Each series the delta names is listed whole, and swept of its own rows
  # alone. A series whose listing fails is not swept this run.
  defp relist_booking_calendar(integration, {:series, events}) do
    {start_time, end_time} = window = Sync.window()
    calendar_id = Defaults.booking_calendar_id(integration)

    listed =
      events
      |> Enum.map(& &1["recurringEventId"])
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()
      |> Enum.filter(&relist_series(integration, calendar_id, &1, start_time, end_time))
      |> Enum.map(&{calendar_id, window, &1})

    {:ok, listed}
  end

  defp relist_series(integration, calendar_id, master_id, start_time, end_time) do
    with {:ok, instances} <-
           Config.google_calendar_api_module().list_instances(
             integration,
             calendar_id,
             master_id,
             start_time,
             end_time
           ),
         :ok <- safe_process_events(integration, instances, calendar_id) do
      true
    else
      failure ->
        Logger.warning("Could not list a changed Google series' instances; not sweeping it",
          calendar_integration_id: integration.id,
          error: LogFormat.reason(failure)
        )

        false
    end
  end

  defp sync_secondary_calendars(integration) do
    case selected_secondary_calendar_ids(integration) do
      [] -> {:ok, []}
      ids -> sync_each_secondary_calendar(integration, ids)
    end
  end

  defp selected_secondary_calendar_ids(integration) do
    primary_id = Defaults.booking_calendar_id(integration)

    integration.calendar_list
    |> Enum.filter(fn cal -> cal.selected == true and cal.id != primary_id end)
    |> Enum.map(& &1.id)
  end

  # Iterates each selected secondary calendar, accumulating the ids of any that
  # no longer exist on Google's side so they can be de-selected in a single write
  # afterwards — preventing a deleted calendar from being re-fetched (and 404ing)
  # on every sync — and the calendars read in full, for the sweep. The
  # accumulator is `{status, missing_ids, listed}`.
  defp sync_each_secondary_calendar(integration, calendar_ids) do
    {start_time, end_time} = window = Sync.window()

    {status, missing_ids, listed} =
      Enum.reduce_while(calendar_ids, {:ok, [], []}, fn calendar_id, {:ok, missing, listed} ->
        case sync_one_secondary_calendar(integration, calendar_id, start_time, end_time) do
          :listed -> {:cont, {:ok, missing, [{calendar_id, window} | listed]}}
          :skipped -> {:cont, {:ok, missing, listed}}
          :not_found -> {:cont, {:ok, [calendar_id | missing], listed}}
          {:halt, value} -> {:halt, {value, missing, listed}}
        end
      end)

    case deselect_missing_calendars(integration, missing_ids) do
      :ok -> if status == :ok, do: {:ok, listed}, else: status
      gone -> gone
    end
  end

  defp sync_one_secondary_calendar(integration, calendar_id, start_time, end_time) do
    case Config.google_calendar_api_module().list_events(
           integration,
           calendar_id,
           start_time,
           end_time
         ) do
      {:ok, events} ->
        case safe_process_events(integration, events, calendar_id) do
          :ok -> :listed
          error -> {:halt, error}
        end

      {:error, :not_found, _message} ->
        Logger.warning("Google Calendar secondary calendar not found; de-selecting",
          calendar_integration_id: integration.id,
          calendar_id: calendar_id
        )

        :not_found

      {:error, :circuit_open} ->
        Logger.warning("Google Calendar circuit breaker open during secondary sync",
          calendar_integration_id: integration.id
        )

        {:halt, {:error, :circuit_open}}

      {:error, :unauthorized, _message} ->
        Logger.warning("Google Calendar secondary sync unauthorised; skipping calendar",
          calendar_integration_id: integration.id,
          calendar_id: calendar_id
        )

        :skipped

      {:error, _type, reason} ->
        Logger.error("Google Calendar secondary sync failed",
          calendar_integration_id: integration.id,
          calendar_id: calendar_id,
          error: LogFormat.reason(reason)
        )

        {:halt, {:error, reason}}

      {:error, reason} ->
        Logger.error("Google Calendar secondary sync failed",
          calendar_integration_id: integration.id,
          calendar_id: calendar_id,
          error: LogFormat.reason(reason)
        )

        {:halt, {:error, reason}}
    end
  end

  defp deselect_missing_calendars(_integration, []), do: :ok

  defp deselect_missing_calendars(integration, missing_ids) do
    case Selection.deselect_missing(integration, missing_ids) do
      {:ok, _updated} ->
        :ok

      # Deleted while this cycle read it: the job is discarded, as any cycle
      # whose integration went is.
      {:error, :not_found} ->
        {:error, :integration_gone}

      {:error, reason} ->
        Logger.error("Failed to de-select missing Google calendars",
          calendar_integration_id: integration.id,
          calendar_ids: missing_ids,
          error: LogFormat.reason(reason)
        )

        :ok
    end
  end

  # Best-effort: normalise all events via the provider, then delegate to
  # the shared persistence pipeline in `Sync`. Cancelled events are handled
  # separately — they are deleted from the cache and reconciled as deletions.
  # `changed?` says the events are changes rather than a listing, so their
  # series' rules are read again however fresh (`SeriesRules.refresh/4`).
  defp safe_process_events(integration, raw_events, calendar_id, changed? \\ false) do
    {cancelled, active} =
      Enum.split_with(raw_events, fn event -> event["status"] == "cancelled" end)

    Sync.reconcile_deletions(integration, Enum.map(cancelled, &cancelled_ref/1))

    context = normalisation_context(integration, calendar_id)

    with {:ok, calendar_events} <- GoogleProvider.normalise_events(active, context) do
      :ok =
        SeriesRules.refresh(integration.id, calendar_events, SeriesMaster.reader(integration),
          changed: changed?
        )

      Sync.persist_normalised_events(integration, calendar_events)
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  defp normalisation_context(integration, calendar_id) do
    %{
      calendar_integration_id: integration.id,
      provider_calendar_id: calendar_id || Defaults.booking_calendar_id(integration),
      synced_at: DateTime.utc_now(:microsecond)
    }
  end

  # An instance is cached under a uid built from its original start, which a
  # cancellation may not carry; its own id addresses the row exactly.
  defp cancelled_ref(%{"recurringEventId" => series_id} = event) when is_binary(series_id),
    do: %{provider_event_id: event["id"], uid: nil}

  defp cancelled_ref(event), do: %{provider_event_id: event["id"], uid: event["iCalUID"]}

  defp persist_sync_state(integration, next_sync_token) do
    attrs =
      maybe_put_sync_token(%{last_external_sync_at: DateTime.utc_now(:second)}, next_sync_token)

    case CalendarIntegrationQueries.update_sync_state(integration, attrs) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Failed to persist Google Calendar sync state",
          calendar_integration_id: integration.id,
          error: LogFormat.reason(changeset)
        )

        :ok
    end
  end

  defp maybe_put_sync_token(attrs, nil), do: attrs
  defp maybe_put_sync_token(attrs, token), do: Map.put(attrs, :google_sync_token, token)
end
