defmodule Tymeslot.Integrations.Calendar.CalDAV.Sync do
  @moduledoc """
  Runs a full or incremental sync of a CalDAV calendar integration.

  ## Sync Tiers

  CalDAV servers vary widely in their protocol support. The tier is probed once
  per integration and stored in `caldav_sync_tier`:

  - **Tier 1** – Server supports `DAV:sync-token` (RFC 6578). After the first
    full fetch, a sync-collection REPORT carrying only the stored token returns
    just the delta since that point.

  - **Tier 2** – Server supports `cs:getctag` (Apple/Sabre extension). A
    lightweight PROPFIND checks whether the CTag has changed, skipping the
    event fetch entirely when the calendar is unchanged.

  - **Tier 3** – Fallback: a full PROPFIND + REPORT calendar-query on every
    run. Required for basic servers supporting neither extension.

  Tiers 1 and 2 are scoped to a single collection, so any calendar beyond the
  primary one always goes through the Tier 3 path.

  ## Reporting rather than deciding

  Outcomes that need an operator- or owner-facing decision are *reported*, not
  acted on here: `{:error, :unauthorized}`, `{:error, :forbidden}` and
  `{:error, :booking_calendar_missing}` all travel back to the caller. Whether
  those mean "flag the integration and stop retrying" or something else is a
  job-scheduling policy question, and lives with the Oban worker that asked for
  the sync.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalDAV.OfflineQueue
  alias Tymeslot.Integrations.Calendar.CalDAV.Sync.EventFetch
  alias Tymeslot.Integrations.Calendar.CalDAV.Sync.State
  alias Tymeslot.Integrations.Calendar.CalDAV.SyncCollectionReport
  alias Tymeslot.Integrations.Calendar.CalDAV.SyncReconciler
  alias Tymeslot.Integrations.Calendar.CalDAV.TierDetector
  alias Tymeslot.Integrations.Calendar.CalDAV.UrlBuilder
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.SyncBroadcast

  @typedoc """
  `:unauthorized`, `:forbidden` and `:booking_calendar_missing` are the reasons
  the caller is expected to interpret; anything else is a transport or server
  failure worth retrying.
  """
  @type result :: :ok | {:error, term()}

  @doc """
  Syncs one integration, broadcasting completion to the owner's dashboard.

  Pending local changes are replayed *before* remote changes are fetched. That
  ordering is what preserves local edits across transient network failures: a
  subsequent pull cannot clobber a local change that has not reached the server
  yet if the push happens first.

  Passing `force_full_fetch?: true` skips tier handling entirely; see
  `forced_full_fetch/2`.
  """
  @spec run(struct(), boolean()) :: result()
  def run(integration, force_full_fetch?) do
    client = CaldavCommon.client_for_integration(integration)

    OfflineQueue.flush(integration, client)

    if force_full_fetch? do
      broadcast_on_success(integration, forced_full_fetch(integration, client))
    else
      run_tiered(integration, client)
    end
  end

  defp run_tiered(integration, client) do
    case detect_tier(integration, client) do
      {:ok, tier, updated} ->
        broadcast_on_success(updated, dispatch(updated, client, tier))

      {:error, _reason} = error ->
        error
    end
  end

  defp broadcast_on_success(integration, :ok) do
    SyncBroadcast.broadcast_sync_complete(integration.user_id, integration.id)
    :ok
  end

  defp broadcast_on_success(_integration, other), do: other

  # ---------------------------------------------------------------------------
  # Forced full fetch
  # ---------------------------------------------------------------------------

  @doc """
  Runs a calendar-query REPORT against every configured path, ignoring the
  tier, then resets the sync token and records the full-sync timestamp.

  Tier 1 delta sync and Tier 2 CTag checks can silently miss events that were
  already on the server when the initial sync ran, so a plain calendar-query
  REPORT is the only way to re-establish ground truth. Clearing the sync token
  makes the next normal sync rebuild its state from scratch, which can
  self-heal a server whose own sync tracking has drifted. Clearing the tier
  forces re-detection, which is otherwise one-shot and would never notice a
  server upgrade that adds sync-collection support.
  """
  @spec forced_full_fetch(struct(), map()) :: result()
  def forced_full_fetch(integration, client) do
    paths = client.calendar_paths

    if Enum.empty?(paths) do
      Logger.debug("No calendar paths configured; skipping forced full fetch",
        calendar_integration_id: integration.id
      )

      :ok
    else
      finish_forced_full_fetch(
        integration,
        EventFetch.fetch_paths(integration, client, paths),
        paths
      )
    end
  end

  defp finish_forced_full_fetch(integration, :ok, paths) do
    # EventFetch has already stamped per-path state; this final write takes
    # precedence and carries the force-specific columns.
    State.put(integration,
      sync_token: nil,
      last_full_sync_at: DateTime.utc_now(:second),
      sync_tier: nil
    )

    Logger.info("CalDAV forced full fetch completed",
      calendar_integration_id: integration.id,
      paths: length(paths)
    )

    :ok
  end

  defp finish_forced_full_fetch(integration, {:error, reason} = error, _paths) do
    log_sync_error(integration, "forced full fetch", reason)
    error
  end

  # ---------------------------------------------------------------------------
  # Tier detection and dispatch
  # ---------------------------------------------------------------------------

  defp detect_tier(%{caldav_sync_tier: nil} = integration, client) do
    case TierDetector.detect(integration, client) do
      {:ok, tier} ->
        Logger.info("CalDAV sync tier detected",
          calendar_integration_id: integration.id,
          tier: tier
        )

        {:ok, tier, State.put_tier(integration, tier)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp detect_tier(%{caldav_sync_tier: tier} = integration, _client), do: {:ok, tier, integration}

  defp dispatch(integration, client, 1), do: tier1(integration, client)
  defp dispatch(integration, client, 2), do: tier2(integration, client)
  defp dispatch(integration, client, _tier), do: tier3(integration, client)

  # Tiers 1 and 2 are single-collection protocols, so the primary path uses the
  # tier's own mechanism and every extra path falls back to a plain fetch.
  defp with_extra_paths(integration, client, tier_name, primary_fun) do
    case client.calendar_paths do
      [] ->
        Logger.debug("No calendar path configured; skipping tiered sync",
          calendar_integration_id: integration.id,
          tier: tier_name
        )

        :ok

      [primary_path] ->
        primary_fun.(primary_path)

      [primary_path | extra_paths] ->
        with :ok <- primary_fun.(primary_path) do
          EventFetch.fetch_paths(integration, client, extra_paths)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Tier 1: sync-collection REPORT (delta sync via DAV:sync-token)
  # ---------------------------------------------------------------------------

  defp tier1(integration, client) do
    with_extra_paths(integration, client, "Tier 1", &do_tier1(integration, client, &1))
  end

  defp do_tier1(integration, client, primary_path) do
    calendar_url = UrlBuilder.build_calendar_url(client.base_url, primary_path)

    case SyncCollectionReport.fetch(integration, client, calendar_url) do
      {:ok, {events, deleted_hrefs, new_sync_token}} ->
        Logger.info("CalDAV Tier 1 sync fetched changes",
          calendar_integration_id: integration.id,
          changed_count: length(events),
          deleted_count: length(deleted_hrefs)
        )

        apply_tier1_delta(integration, events, deleted_hrefs, new_sync_token)

      {:error, :sync_token_expired} ->
        Logger.info("CalDAV sync token expired; falling back to full fetch",
          calendar_integration_id: integration.id
        )

        State.put(integration, sync_token: nil)
        tier3(integration, client)

      # The server named the changed resources but did not inline their
      # calendar data, so the delta cannot be applied on its own. The token is
      # deliberately kept: it stays valid, and the next cycle is offered the
      # same changes again, so nothing is lost if this fetch fails.
      {:error, :calendar_data_withheld} ->
        Logger.info("CalDAV sync-collection returned no event data; falling back to full fetch",
          calendar_integration_id: integration.id
        )

        tier3(integration, client)

      {:error, :not_found} ->
        {:error, :booking_calendar_missing}

      {:error, reason} ->
        log_unless_actionable(integration, "Tier 1 sync", reason)
        {:error, reason}
    end
  end

  defp apply_tier1_delta(integration, events, deleted_hrefs, new_sync_token) do
    case SyncReconciler.process_tier1(integration, events, deleted_hrefs) do
      :ok ->
        State.put(integration, sync_token: new_sync_token)
        :ok

      {:error, reason} ->
        Logger.error("CalDAV Tier 1 event processing failed; sync token NOT updated",
          calendar_integration_id: integration.id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Tier 2: getctag check + conditional full fetch
  # ---------------------------------------------------------------------------

  defp tier2(integration, client) do
    with_extra_paths(integration, client, "Tier 2", &do_tier2(integration, client, &1))
  end

  defp do_tier2(integration, client, primary_path) do
    calendar_url = UrlBuilder.build_calendar_url(client.base_url, primary_path)

    case SyncCollectionReport.fetch_ctag(calendar_url, client) do
      {:ok, current_ctag} ->
        ctag_result(integration, client, primary_path, current_ctag)

      {:error, :not_found} ->
        {:error, :booking_calendar_missing}

      {:error, reason} when reason in [:unauthorized, :forbidden] ->
        {:error, reason}

      {:error, reason} ->
        # A CTag probe is an optimisation, not the sync itself: if it fails for
        # any reason short of auth or a missing collection, fetching everything
        # still produces a correct result.
        log_sync_error(integration, "Tier 2 CTag check", reason)
        EventFetch.fetch_primary(integration, client, primary_path, [])
    end
  end

  defp ctag_result(integration, client, primary_path, current_ctag) do
    stored_ctag = integration.caldav_sync_token

    if current_ctag == stored_ctag and not is_nil(stored_ctag) do
      Logger.debug("CalDAV CTag unchanged; skipping event fetch",
        calendar_integration_id: integration.id
      )

      State.put(integration, [])
      :ok
    else
      EventFetch.fetch_primary(integration, client, primary_path,
        new_ctag: current_ctag,
        ctag_paths: [primary_path]
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Tier 3: full calendar-query REPORT
  # ---------------------------------------------------------------------------

  defp tier3(integration, client) do
    paths = client.calendar_paths

    if Enum.empty?(paths) do
      Logger.debug("No calendar paths configured for CalDAV sync",
        calendar_integration_id: integration.id
      )

      :ok
    else
      EventFetch.fetch_paths(integration, client, paths)
    end
  end

  # Auth failures and a missing booking calendar are reported upwards for the
  # caller to act on, and logging them here would double up on the log line the
  # caller writes when it does.
  defp log_unless_actionable(_integration, _phase, reason)
       when reason in [:unauthorized, :forbidden, :booking_calendar_missing],
       do: :ok

  defp log_unless_actionable(integration, phase, reason),
    do: log_sync_error(integration, phase, reason)

  defp log_sync_error(integration, phase, reason) do
    Logger.error("CalDAV sync failed",
      calendar_integration_id: integration.id,
      phase: phase,
      error: inspect(reason)
    )
  end
end
