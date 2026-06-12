defmodule Tymeslot.Workers.SyncCalDavCalendarWorker do
  @moduledoc """
  Oban worker that performs a full or incremental sync of a CalDAV calendar
  integration.

  ## Sync Tiers

  CalDAV servers vary widely in their protocol support. The worker probes each
  server once and stores the detected tier in `caldav_sync_tier`:

  - **Tier 1** – Server supports `DAV:sync-token` (RFC 6578). After the first
    full fetch the worker sends a sync-collection REPORT containing only the
    stored token; the server returns only the delta since that point.

  - **Tier 2** – Server supports `cs:getctag` (Apple/Sabre extension). The
    worker does a lightweight PROPFIND to check if the CTag has changed and
    skips fetching events when the calendar is unchanged.

  - **Tier 3** – Fallback: a full PROPFIND + REPORT calendar-query on every
    run. Required for basic CalDAV servers that support neither extension.

  ## Per-integration deduplication

  `unique: [period: 300, keys: [:calendar_integration_id]]` prevents duplicate
  jobs from accumulating when a sweep worker or external trigger enqueues a job
  for an integration that already has one queued or running.

  ## Auth errors (REQ-012)

  A 401 or 403 response flags the integration's `needs_reauth` field and
  returns `{:discard, …}` (no retry — the failure is permanent until the user
  reconnects). If the DB write itself fails, the worker returns `{:error, …}`
  so Oban retries and takes another shot at recording the flag. The
  `is_active` flag is left unchanged so the integration remains visible in the
  dashboard.
  """

  use Oban.Worker,
    queue: :calendar_events,
    max_attempts: 3,
    unique: [
      period: 300,
      keys: [:calendar_integration_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  require Logger

  alias Tymeslot.Integrations.Calendar.CalDAV.Events, as: CalDAVEvents
  alias Tymeslot.Integrations.Calendar.CalDAV.OfflineQueue
  alias Tymeslot.Integrations.Calendar.CalDAV.SyncCollectionReport
  alias Tymeslot.Integrations.Calendar.CalDAV.SyncReconciler
  alias Tymeslot.Integrations.Calendar.CalDAV.TierDetector
  alias Tymeslot.Integrations.Calendar.CalDAV.UrlBuilder
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.HealthCheck

  # How far back and forward to fetch events on a full sync.
  # Centralised in ProviderConfig so all providers use the same window.
  @sync_window_past_days ProviderConfig.sync_window_past_days()
  @sync_window_future_days ProviderConfig.sync_window_future_days()

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    integration_id = Map.fetch!(args, "calendar_integration_id")
    force_full_fetch? = Map.get(args, "force_full_fetch", false) == true

    Logger.metadata(calendar_integration_id: integration_id)

    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, integration} ->
        sync_integration(integration, force_full_fetch?)

      {:error, :not_found} ->
        Logger.warning("CalDAV integration not found, discarding sync job",
          calendar_integration_id: integration_id
        )

        {:discard, "Integration not found"}

      {:error, :requires_reencryption, integration} ->
        CalendarManagement.handle_reauth_required(integration)
    end
  end

  # ---------------------------------------------------------------------------
  # Orchestration
  # ---------------------------------------------------------------------------

  defp sync_integration(integration, force_full_fetch?) do
    client = build_client(integration)

    # Replay any pending local changes BEFORE fetching remote changes.
    # This ordering is what preserves local edits across transient network
    # failures — a subsequent pull cannot clobber a local change that
    # hasn't reached the server yet if we push first.
    OfflineQueue.flush(integration, client)

    if force_full_fetch? do
      case sync_forced_full_fetch(integration, client) do
        :ok ->
          SyncBroadcast.broadcast_sync_complete(integration.user_id, integration.id)
          :ok

        other ->
          other
      end
    else
      case maybe_detect_tier(integration, client) do
        {:ok, tier, updated_integration} ->
          case do_sync(updated_integration, client, tier) do
            :ok ->
              SyncBroadcast.broadcast_sync_complete(
                updated_integration.user_id,
                updated_integration.id
              )

              :ok

            other ->
              other
          end

        {:error, :unauthorized} ->
          flag_reauth_required(integration)

        {:error, :forbidden} ->
          flag_reauth_required(integration)
      end
    end
  end

  # Forced full fetch: runs a calendar-query REPORT against every configured
  # calendar path, upserts all events, detects deletions, and on success resets
  # the sync token to nil + updates last_full_sync_at. Never consults the tier.
  #
  # Rationale: Tier 1 delta sync and Tier 2 ctag checks can silently miss events
  # that were present on the server when the initial sync ran. Running a plain
  # calendar-query REPORT captures ground truth. Resetting the sync token means
  # the next normal delta sync re-establishes state from scratch, which may
  # self-heal the server's sync tracking.
  defp sync_forced_full_fetch(integration, client) do
    paths = client.calendar_paths

    if Enum.empty?(paths) do
      Logger.debug("No calendar paths configured; skipping forced full fetch",
        calendar_integration_id: integration.id
      )

      :ok
    else
      result =
        Enum.reduce_while(paths, :ok, fn path, _acc ->
          case do_full_fetch(integration, client, path, []) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)

      case result do
        :ok ->
          # do_full_fetch has already called persist_sync_state per path (without
          # the new options). Now write the force-specific fields in one final
          # update that takes precedence.
          #
          # Resetting caldav_sync_tier to nil triggers re-detection on the next
          # normal sync. Tier detection is otherwise one-shot and would never
          # notice a server upgrade that enables sync-collection support.
          persist_sync_state(integration,
            sync_token: nil,
            last_full_sync_at: DateTime.utc_now(:second),
            sync_tier: nil
          )

          Logger.info("CalDAV forced full fetch completed",
            calendar_integration_id: integration.id,
            paths: length(paths)
          )

          :ok

        {:discard, _reason} = discard ->
          discard

        {:error, reason} ->
          log_sync_error(integration, "forced full fetch", reason)
          {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Tier detection
  # ---------------------------------------------------------------------------

  defp maybe_detect_tier(%{caldav_sync_tier: nil} = integration, client) do
    case TierDetector.detect(integration, client) do
      {:ok, tier} ->
        Logger.info("CalDAV sync tier detected",
          calendar_integration_id: integration.id,
          tier: tier
        )

        updated = persist_sync_tier(integration, tier)
        {:ok, tier, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_detect_tier(%{caldav_sync_tier: tier} = integration, _client) do
    {:ok, tier, integration}
  end

  # ---------------------------------------------------------------------------
  # Sync dispatch by tier
  # ---------------------------------------------------------------------------

  defp do_sync(integration, client, 1), do: sync_tier1(integration, client)
  defp do_sync(integration, client, 2), do: sync_tier2(integration, client)
  defp do_sync(integration, client, _tier), do: sync_tier3(integration, client)

  # ---------------------------------------------------------------------------
  # Tier 1: sync-collection REPORT (delta sync via DAV:sync-token)
  # ---------------------------------------------------------------------------

  defp sync_tier1(integration, client) do
    case client.calendar_paths do
      [] ->
        Logger.debug("No calendar path configured; skipping Tier 1 sync",
          calendar_integration_id: integration.id
        )

        :ok

      [primary_path] ->
        do_sync_tier1(integration, client, primary_path)

      [primary_path | extra_paths] ->
        with :ok <- do_sync_tier1(integration, client, primary_path) do
          Enum.reduce_while(extra_paths, :ok, fn path, _acc ->
            case do_full_fetch(integration, client, path, []) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
        end
    end
  end

  defp do_sync_tier1(integration, client, primary_path) do
    calendar_url = UrlBuilder.build_calendar_url(client.base_url, primary_path)

    case SyncCollectionReport.fetch(integration, client, calendar_url) do
      {:ok, {events, deleted_hrefs, new_sync_token}} ->
        Logger.info("CalDAV Tier 1 sync fetched changes",
          calendar_integration_id: integration.id,
          changed_count: length(events),
          deleted_count: length(deleted_hrefs)
        )

        case SyncReconciler.process_tier1(integration, events, deleted_hrefs) do
          :ok ->
            persist_sync_state(integration, sync_token: new_sync_token)
            :ok

          {:error, reason} ->
            Logger.error("CalDAV Tier 1 event processing failed; sync token NOT updated",
              calendar_integration_id: integration.id,
              error: inspect(reason)
            )

            {:error, reason}
        end

      {:error, :sync_token_expired} ->
        # Clear stale token and fall back to full fetch
        Logger.info("CalDAV sync token expired; falling back to full fetch",
          calendar_integration_id: integration.id
        )

        persist_sync_state(integration, sync_token: nil)
        sync_tier3(integration, client)

      {:error, :unauthorized} ->
        flag_reauth_required(integration)

      {:error, :forbidden} ->
        flag_reauth_required(integration)

      {:error, reason} ->
        log_sync_error(integration, "Tier 1 sync", reason)
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Tier 2: getctag check + conditional full fetch
  # ---------------------------------------------------------------------------

  defp sync_tier2(integration, client) do
    case client.calendar_paths do
      [] ->
        Logger.debug("No calendar path configured; skipping Tier 2 sync",
          calendar_integration_id: integration.id
        )

        :ok

      [primary_path] ->
        do_sync_tier2(integration, client, primary_path)

      [primary_path | extra_paths] ->
        with :ok <- do_sync_tier2(integration, client, primary_path) do
          Enum.reduce_while(extra_paths, :ok, fn path, _acc ->
            case do_full_fetch(integration, client, path, []) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
        end
    end
  end

  defp do_sync_tier2(integration, client, primary_path) do
    calendar_url = UrlBuilder.build_calendar_url(client.base_url, primary_path)

    case SyncCollectionReport.fetch_ctag(calendar_url, client) do
      {:ok, current_ctag} ->
        stored_ctag = integration.caldav_sync_token

        if current_ctag == stored_ctag and not is_nil(stored_ctag) do
          Logger.debug("CalDAV CTag unchanged; skipping event fetch",
            calendar_integration_id: integration.id
          )

          persist_sync_state(integration, [])
          :ok
        else
          do_full_fetch(integration, client, primary_path,
            new_ctag: current_ctag,
            ctag_paths: [primary_path]
          )
        end

      {:error, :unauthorized} ->
        flag_reauth_required(integration)

      {:error, :forbidden} ->
        flag_reauth_required(integration)

      {:error, reason} ->
        log_sync_error(integration, "Tier 2 CTag check", reason)
        # Fall back to full fetch on CTag probe failure
        do_full_fetch(integration, client, primary_path, [])
    end
  end

  # ---------------------------------------------------------------------------
  # Tier 3: full calendar-query REPORT
  # ---------------------------------------------------------------------------

  defp sync_tier3(integration, client) do
    paths = client.calendar_paths

    if Enum.empty?(paths) do
      Logger.debug("No calendar paths configured for CalDAV sync",
        calendar_integration_id: integration.id
      )

      :ok
    else
      Enum.reduce_while(paths, :ok, fn path, _acc ->
        case do_full_fetch(integration, client, path, []) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Full event fetch (used by Tier 2 on CTag change and Tier 3)
  # ---------------------------------------------------------------------------

  defp do_full_fetch(integration, client, calendar_path, opts) do
    range_now = DateTime.utc_now()
    start_time = DateTime.add(range_now, -@sync_window_past_days, :day)
    end_time = DateTime.add(range_now, @sync_window_future_days, :day)

    case CalDAVEvents.fetch_events(client, calendar_path, start_time, end_time) do
      {:ok, events} ->
        Logger.info("CalDAV full fetch completed",
          calendar_integration_id: integration.id,
          event_count: length(events),
          calendar_path: calendar_path
        )

        case SyncReconciler.process_full_fetch(
               integration,
               events,
               start_time,
               end_time,
               range_now,
               calendar_path
             ) do
          :ok ->
            sync_token_opt =
              case Keyword.get(opts, :new_ctag) do
                nil -> []
                ctag -> [sync_token: ctag]
              end

            persist_sync_state(integration, sync_token_opt)
            :ok

          {:error, reason} ->
            Logger.error("CalDAV full fetch event processing failed; sync token NOT updated",
              calendar_integration_id: integration.id,
              calendar_path: calendar_path,
              error: inspect(reason)
            )

            {:error, reason}
        end

      {:error, :unauthorized} ->
        flag_reauth_required(integration)

      {:error, :forbidden} ->
        flag_reauth_required(integration)

      {:error, reason} ->
        log_sync_error(integration, "full fetch", reason)
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # State persistence
  # ---------------------------------------------------------------------------

  defp persist_sync_tier(integration, tier) do
    case CalendarIntegrationQueries.update_sync_state(integration, %{caldav_sync_tier: tier}) do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        Logger.warning("Failed to persist CalDAV sync tier",
          calendar_integration_id: integration.id,
          error: inspect(changeset)
        )

        %{integration | caldav_sync_tier: tier}
    end
  end

  defp persist_sync_state(integration, opts) do
    base_attrs = %{last_external_sync_at: DateTime.utc_now(:second)}

    attrs =
      base_attrs
      |> maybe_put(opts, :sync_token, :caldav_sync_token)
      |> maybe_put(opts, :last_full_sync_at, :last_full_sync_at)
      |> maybe_put(opts, :sync_tier, :caldav_sync_tier)

    result = CalendarIntegrationQueries.update_sync_state(integration, attrs)
    HealthCheck.mark_synced_successfully(:calendar, integration.id)

    case result do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Failed to persist CalDAV sync state",
          calendar_integration_id: integration.id,
          error: inspect(changeset)
        )

        :ok
    end
  end

  defp maybe_put(attrs, opts, opt_key, attr_key) do
    case Keyword.fetch(opts, opt_key) do
      {:ok, value} -> Map.put(attrs, attr_key, value)
      :error -> attrs
    end
  end

  # ---------------------------------------------------------------------------
  # Client construction
  # ---------------------------------------------------------------------------

  defp build_client(integration) do
    CaldavCommon.build_client(
      %{
        base_url: integration.base_url,
        username: integration.username,
        password: integration.password,
        calendar_paths: integration.calendar_paths,
        verify_ssl: Map.get(integration, :verify_ssl, true)
      },
      provider: provider_atom(integration.provider)
    )
  end

  defp provider_atom(provider) when is_binary(provider) do
    case provider do
      "radicale" -> :radicale
      "nextcloud" -> :nextcloud
      "zimbra" -> :zimbra
      "mailbox_org" -> :mailbox_org
      _other -> :caldav
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp flag_reauth_required(integration) do
    Logger.warning("CalDAV sync unauthorised; flagging for reauth",
      calendar_integration_id: integration.id
    )

    case CalendarManagement.mark_needs_reauth(
           integration,
           "CalDAV server rejected the stored credentials. Please reconnect the integration."
         ) do
      {:ok, _updated} ->
        {:discard, "CalDAV server rejected credentials — reauthentication required"}

      {:error, _changeset} ->
        {:error, "Failed to flag integration for reauth"}
    end
  end

  defp log_sync_error(integration, phase, reason) do
    Logger.error("CalDAV sync failed",
      calendar_integration_id: integration.id,
      phase: phase,
      error: inspect(reason)
    )
  end
end
