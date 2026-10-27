defmodule Tymeslot.Integrations.Calendar.SyncSchedule do
  @moduledoc """
  When each calendar provider syncs, and how a sync of one is asked for: the
  one table the fallback sweep, the calendar grid and the owner's Refresh
  read.

  Each provider has:

    * a **worker**, the job a sync of it runs as;
    * a **request**, the sync the owner asks for (Refresh, an import, a
      write to the grid), which goes through `Tymeslot.Workers.SyncRequest`
      so that a request made while a sync runs reruns it rather than being
      folded into a run that may have read the calendar before the change;
    * a sweep **interval**, how often the fallback sweep starts a sync;
    * a **stale threshold**, after which the grid shows the integration's
      events as out of date.

  The stale threshold is deliberately longer than the interval: it is the
  interval plus the queue wait, network latency and retries a sync can
  take, so a calendar syncing on schedule never reads as stale.

  A provider missing from the table is refused (`{:error,
  :unsupported_provider}`) rather than handed to some default worker.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Jobs
  alias Tymeslot.Workers.RefreshOutlookCalendarWorker
  alias Tymeslot.Workers.SyncCalDavCalendarWorker
  alias Tymeslot.Workers.SyncDebugCalendarWorker
  alias Tymeslot.Workers.SyncExchangeCalendarWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker
  alias Tymeslot.Workers.SyncIcsCalendarWorker

  # Google and Outlook are synced on every sweep (every 15 minutes): their
  # webhooks keep them current, and the sweep is the net for a missed one.
  @every_sweep 0

  # CalDAV syncs by tier. Tier 1 (sync-token delta) and 2 (CTag check) are
  # cheap; tier 3 is a full fetch every time. An undetected tier syncs as
  # often as tier 1, so it is detected soon.
  @caldav_tiers %{
    1 => %{interval_seconds: 900, stale_after_minutes: 25},
    2 => %{interval_seconds: 1_800, stale_after_minutes: 45},
    3 => %{interval_seconds: 3_600, stale_after_minutes: 90}
  }
  @caldav_undetected_tier 1

  @schedules %{
    "google" => %{
      worker: SyncGoogleCalendarWorker,
      interval_seconds: @every_sweep,
      stale_after_minutes: 30
    },
    "outlook" => %{
      worker: RefreshOutlookCalendarWorker,
      interval_seconds: @every_sweep,
      stale_after_minutes: 30
    },
    # A published feed has no delta mechanism, and its publisher regenerates
    # it on its own schedule: polling harder costs a third party bandwidth
    # for data that has not changed, and a feed an hour old is normal.
    "ics_url" => %{
      worker: SyncIcsCalendarWorker,
      interval_seconds: 1_800,
      stale_after_minutes: 75
    },
    # EWS reads the whole window each run, twice over (free/busy for
    # availability, items for the grid).
    "exchange" => %{
      worker: SyncExchangeCalendarWorker,
      interval_seconds: 1_800,
      stale_after_minutes: 45
    },
    # The debug provider is never swept: it syncs when asked.
    "debug" => %{
      worker: SyncDebugCalendarWorker,
      interval_seconds: nil,
      stale_after_minutes: 15
    }
  }

  @typedoc """
  A provider's schedule. `interval_seconds` is `0` for a provider synced on
  every sweep and `nil` for one the sweep leaves alone.
  """
  @type schedule :: %{
          worker: module(),
          interval_seconds: non_neg_integer() | nil,
          stale_after_minutes: pos_integer()
        }

  @doc "The schedule of `integration`'s provider."
  @spec schedule(CalendarIntegrationSchema.t() | %{provider: String.t()}) ::
          {:ok, schedule()} | {:error, :unsupported_provider}
  def schedule(%{provider: provider} = integration) do
    cond do
      Map.has_key?(@schedules, provider) ->
        {:ok, Map.fetch!(@schedules, provider)}

      provider in ProviderConfig.caldav_based_provider_strings() ->
        tier =
          Map.get(
            @caldav_tiers,
            Map.get(integration, :caldav_sync_tier),
            @caldav_tiers[@caldav_undetected_tier]
          )

        {:ok, Map.put(tier, :worker, SyncCalDavCalendarWorker)}

      true ->
        {:error, :unsupported_provider}
    end
  end

  @doc """
  Asks for a sync of `integration` now, as the owner's Refresh does.

  A CalDAV-family request forces a full fetch: owners ask because they
  believe something is missing, and a delta sync is exactly what would miss
  it. A Google request reads the booking calendar in full too.
  """
  @spec request_sync(CalendarIntegrationSchema.t() | %{provider: String.t(), id: pos_integer()}) ::
          {:ok, Oban.Job.t()} | {:error, :unsupported_provider | term()}
  def request_sync(integration) do
    with {:ok, %{worker: worker}} <- schedule(integration) do
      request(worker, integration.id)
    end
  end

  @doc """
  Asks for a sync of `integration` because the grid was opened on stale
  events: as `request_sync/1` does, except that a sync already waiting out
  an error's backoff (a failed attempt, or a snooze past an open breaker or
  a rate limit) is left to it, `{:ok, :backing_off}`. Opening the grid
  again and again must not hammer a provider that is failing; the owner's
  explicit Refresh goes through `request_sync/1` and does bring it forward.

  The check is not atomic with the request: a sync that fails in between
  is brought forward once, as on any request.
  """
  @spec request_sync_unless_backing_off(
          CalendarIntegrationSchema.t()
          | %{provider: String.t(), id: pos_integer()}
        ) ::
          {:ok, Oban.Job.t() | :backing_off} | {:error, :unsupported_provider | term()}
  def request_sync_unless_backing_off(integration) do
    with {:ok, %{worker: worker}} <- schedule(integration) do
      if Jobs.backing_off?(worker, %{"calendar_integration_id" => integration.id}),
        do: {:ok, :backing_off},
        else: request(worker, integration.id)
    end
  end

  defp request(SyncCalDavCalendarWorker, id), do: SyncCalDavCalendarWorker.enqueue_full_fetch(id)
  defp request(worker, id), do: worker.enqueue(id)

  @doc """
  Whether the fallback sweep should start a sync of `integration` at `now`:
  never synced, or last synced longer ago than its interval. False for a
  provider the sweep leaves alone or does not know.
  """
  @spec due?(CalendarIntegrationSchema.t(), DateTime.t()) :: boolean()
  def due?(integration, now) do
    case schedule(integration) do
      {:ok, %{interval_seconds: nil}} -> false
      {:ok, %{interval_seconds: @every_sweep}} -> true
      {:ok, %{interval_seconds: interval}} -> older_than?(integration, now, interval)
      {:error, :unsupported_provider} -> false
    end
  end

  @doc """
  Whether `integration`'s cached events are stale at `now`: never synced, or
  last synced longer ago than its stale threshold.
  """
  @spec stale?(CalendarIntegrationSchema.t(), DateTime.t()) :: boolean()
  def stale?(integration, now) do
    case schedule(integration) do
      {:ok, %{stale_after_minutes: minutes}} -> older_than?(integration, now, minutes * 60)
      {:error, :unsupported_provider} -> false
    end
  end

  defp older_than?(%{last_external_sync_at: nil}, _now, _seconds), do: true

  defp older_than?(%{last_external_sync_at: synced_at}, now, seconds),
    do: DateTime.before?(synced_at, DateTime.add(now, -seconds, :second))
end
