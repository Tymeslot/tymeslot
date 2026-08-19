defmodule Tymeslot.Workers.SyncExchangeCalendarWorker do
  @moduledoc """
  Oban worker that refreshes an Exchange mailbox into the local event cache.

  ## Two reads, two halves of the cache

  EWS answers the two questions this product asks with two different
  operations, and neither subsumes the other (see
  `Tymeslot.Integrations.Calendar.Exchange.Provider`):

    * `GetUserAvailability` says **when the mailbox is busy**, with recurring
      series expanded server-side. Its intervals carry no identity at all, so
      they are stored under a synthesised uid as `busy_only` rows and are the
      only Exchange rows that block a slot.
    * `FindItem` + a batched `GetItem` say **what each event is**: subject,
      location, change key. Those become `display_only` rows, which the
      dashboard grid renders and which block nothing, because a recurring
      master's dates describe only its own first occurrence and would free up
      every later one.

  Both halves belong to the same integration, so each is replaced through
  `Calendar.Sync.full_refresh_for_role/3` rather than the unscoped full
  refresh: that one deletes *every* row an integration holds, which would have
  each half wipe the other's on every cycle.

  The availability read runs first and its failure ends the run without
  writing anything. The item read failing afterwards costs the grid its
  freshness and nothing more, which is the right way round: the busy rows are
  already written and correct.

  ## No incremental mechanism

  EWS offers `SyncFolderItems` with a state token; wiring it up is deferred,
  so every run re-reads the whole sync window. Full replacement is also what
  makes deletions visible, exactly as it is for `SyncIcsCalendarWorker`: an
  event that has vanished simply is not in the replacement set.

  ## What this worker deliberately does not do

  It never calls `Calendar.Sync.post_commit_reconciliation/2`. That resolves a
  vanished provider event to a Tymeslot meeting **by uid** and cancels it,
  notifying both parties, and a busy interval's uid is synthesised rather than
  the server's. `SyncIcsCalendarWorker` skips it too, on the narrower grounds
  that a read-only mirror should not rewrite meetings; here it is also the
  structural half of the defence against a synthesised uid cancelling a real
  booking, the other half being the namespace
  `Exchange.IntervalNormaliser` puts on those uids.

  ## Failure handling

  A 401 or 403 means the stored password no longer works or the account may
  not read the mailbox, which no amount of retrying fixes: the integration is
  flagged for reconnection and the job discarded. A 5xx is discarded too — the
  retry that matters is the next scheduled cycle, not three attempts inside a
  minute, and exhausting them raises a permanent-failure alert about an outage
  no operator here can fix. The vocabulary is CalDAV's throughout, because
  `Exchange.Client` answers in it.

  The empty-response guard mirrors `SyncIcsCalendarWorker`'s and is applied
  per role. A successful call that returns nothing is far more likely a bad
  read than a genuinely emptied mailbox once the cache already holds rows, and
  emptying the busy half on that signal is precisely the "fully booked mailbox
  reported as free" outcome this whole design exists to prevent.
  """

  use Oban.Worker,
    queue: :calendar_events,
    max_attempts: 3,
    unique: [
      period: 300,
      keys: [:calendar_integration_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Integrations.Calendar.CalDAV.Errors, as: CalDAVErrors
  alias Tymeslot.Integrations.Calendar.CalendarEventQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.EventRole
  alias Tymeslot.Integrations.Calendar.Exchange.IntervalNormaliser
  alias Tymeslot.Integrations.Calendar.Exchange.Provider
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.HealthCheck

  @busy_only EventRole.busy_only()
  @display_only EventRole.display_only()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"calendar_integration_id" => integration_id}}) do
    Logger.metadata(calendar_integration_id: integration_id)

    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, integration} ->
        integration
        |> sync()
        |> handle_result(integration)

      {:error, :not_found} ->
        Logger.warning("Exchange integration not found, discarding sync job",
          calendar_integration_id: integration_id
        )

        {:discard, "Integration not found"}

      {:error, :requires_reencryption, integration} ->
        CalendarManagement.handle_reauth_required(integration)
    end
  end

  # The order is the design, not an accident: availability first, and its
  # failure stops the run before either half of the cache is touched.
  defp sync(integration) do
    {from, to} = window()

    with {:ok, busy_uids} <- refresh_busy_intervals(integration, from, to),
         {:ok, item_uids} <- refresh_items(integration, from, to) do
      {:ok, busy_uids ++ item_uids}
    end
  end

  # --- The availability half ---

  defp refresh_busy_intervals(integration, from, to) do
    context = %{calendar_integration_id: integration.id, synced_at: DateTime.utc_now()}

    with {:ok, intervals} <-
           Provider.list_busy_intervals(integration, start_time: from, end_time: to),
         {:ok, events} <- IntervalNormaliser.normalise_intervals(intervals, context) do
      write(integration, @busy_only, events, from, to)
    end
  end

  # --- The grid half ---

  # One client config per selected calendar. A failure on any one of them
  # fails the item read rather than caching a partial view: half a mailbox on
  # the grid is a grid nobody can trust.
  defp refresh_items(integration, from, to) do
    with {:ok, events} <- fetch_all_calendars(integration, from, to) do
      write(integration, @display_only, events, from, to)
    end
  end

  defp fetch_all_calendars(integration, from, to) do
    integration
    |> Provider.build_client_configs()
    |> Enum.reduce_while({:ok, []}, fn client, {:ok, acc} ->
      case fetch_one_calendar(integration, client, from, to) do
        {:ok, events} -> {:cont, {:ok, acc ++ events}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp fetch_one_calendar(integration, client, from, to) do
    calendar_id = client[:calendar_id]

    context = %{
      calendar_integration_id: integration.id,
      provider_calendar_id: to_string(calendar_id),
      synced_at: DateTime.utc_now()
    }

    with {:ok, items} <-
           Provider.list_events(client, start_time: from, end_time: to, calendar_id: calendar_id) do
      Provider.normalise_events(items, context)
    end
  end

  # --- Writing ---

  defp write(integration, role, events, from, to) do
    if events == [] and populated?(integration, role, from, to) do
      {:error, {:empty_result_with_populated_cache, role}}
    else
      case Sync.full_refresh_for_role(integration, role, events) do
        {:ok, _count} -> {:ok, Enum.map(events, & &1.uid)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Scoped to the role being replaced. Asking whether the integration holds
  # *any* rows would have a populated grid half veto an honestly empty
  # availability half, and vice versa.
  defp populated?(integration, role, from, to) do
    CalendarEventQueries.any_in_range_for_role?(integration.id, role, from, to)
  end

  # --- Outcomes ---

  defp handle_result({:ok, uids}, integration) do
    Sync.invalidate_cache_for_user(integration)
    SyncBroadcast.broadcast_cache_update(integration.user_id, uids)

    mark_synced(integration, length(uids))
    SyncBroadcast.broadcast_sync_complete(integration.user_id, integration.id)
    :ok
  end

  # The server rejected the stored credentials, or will not let this account
  # read the mailbox. Retrying re-sends the same rejected credentials.
  defp handle_result({:error, reason}, integration) when reason in [:unauthorized, :forbidden] do
    Logger.warning("Exchange sync unauthorised; flagging for reconnection",
      calendar_integration_id: integration.id
    )

    CalendarManagement.flag_for_reconnection(
      integration,
      dgettext(
        "dashboard_calendar_providers",
        "The Exchange server rejected the stored credentials. Please reconnect the integration."
      ),
      "Exchange server rejected credentials — reauthentication required"
    )
  end

  # `GetUserAvailability` addresses a mailbox, and this integration names none
  # that can be addressed. No retry can invent one; the owner has to supply an
  # address, so the dashboard is told and the job discarded.
  defp handle_result({:error, :no_mailbox_address}, integration) do
    CalendarManagement.flag_for_reconnection(
      integration,
      dgettext(
        "dashboard_calendar_providers",
        "Tymeslot needs the mailbox's email address to read its free/busy time. Please reconnect the integration and provide it."
      ),
      "Exchange integration has no addressable mailbox"
    )
  end

  # A 5xx is the remote failing, not the request being wrong, but the retry
  # that matters is the next cycle: three attempts span under a minute, far
  # too short for a broken server to recover, and exhausting them raises a
  # permanent-failure alert every cycle about an outage no operator here can
  # fix. Returning `{:unexpected_status, 503}` instead of `:server_error`
  # would land in neither this clause nor the terminal one below, which is why
  # `Exchange.Client` classifies every 5xx before it gets here.
  defp handle_result({:error, :server_error}, integration) do
    record_failure(integration, :server_error)

    {:discard, "Exchange server returned a server error; the next scheduled sync will retry"}
  end

  defp handle_result({:error, reason} = result, integration) do
    record_failure(integration, reason)

    if CalDAVErrors.terminal_error?(reason) do
      {:discard,
       "Exchange server refused the sync request: #{CalDAVErrors.describe_error(reason)}"}
    else
      result
    end
  end

  defp mark_synced(integration, count) do
    now = DateTime.utc_now(:second)

    attrs = %{
      last_sync_at: now,
      last_external_sync_at: now,
      last_full_sync_at: now,
      sync_error: nil,
      needs_reauth: false
    }

    case CalendarIntegrationQueries.update_sync_state(integration, attrs) do
      {:ok, _updated} ->
        HealthCheck.mark_synced_successfully(:calendar, integration.id)

        Logger.info("Exchange calendar refreshed",
          calendar_integration_id: integration.id,
          event_count: count
        )

        :ok

      {:error, changeset} ->
        Logger.warning("Failed to persist Exchange sync state",
          calendar_integration_id: integration.id,
          error: inspect(changeset)
        )

        :ok
    end
  end

  defp record_failure(integration, reason) do
    Logger.error("Exchange calendar sync failed",
      calendar_integration_id: integration.id,
      error: inspect(reason)
    )

    CalendarIntegrationQueries.mark_sync_error(integration, error_message(reason))

    :ok
  end

  defp window do
    now = DateTime.utc_now()

    {DateTime.add(now, -ProviderConfig.sync_window_past_days(), :day),
     DateTime.add(now, ProviderConfig.sync_window_future_days(), :day)}
  end

  # The guarded refusal gets its own sentence per half, because the two say
  # very different things to the owner: one means the diary would have been
  # emptied, the other that the grid would have gone blank.
  defp error_message({:empty_result_with_populated_cache, @busy_only}) do
    dgettext(
      "dashboard_calendar_providers",
      "Exchange reported no busy time at all, but the cache still holds some. Keeping it in place and retrying rather than treating your diary as free."
    )
  end

  defp error_message({:empty_result_with_populated_cache, _role}) do
    dgettext(
      "dashboard_calendar_providers",
      "Exchange returned no calendar events, but the cache still holds some. Keeping them in place and retrying rather than emptying your calendar view."
    )
  end

  defp error_message({:soap_fault, _message}) do
    dgettext(
      "dashboard_calendar_providers",
      "The Exchange server rejected the request."
    )
  end

  defp error_message(:no_response_code) do
    dgettext(
      "dashboard_calendar_providers",
      "The Exchange server answered the free/busy request with nothing Tymeslot could read. Retrying rather than treating your diary as free."
    )
  end

  defp error_message({:response_code, _code}), do: error_message(:no_response_code)
  defp error_message({:free_busy_view_type, _view}), do: error_message(:no_response_code)

  # Everything else is a transport failure `Exchange.Client` named in CalDAV's
  # own vocabulary, so it is worded by the module that owns that vocabulary
  # rather than given a second Exchange-flavoured sentence here.
  defp error_message(reason), do: CalDAVErrors.describe_error(reason)
end
