defmodule Tymeslot.Integrations.Calendar.CalDAV.Sync do
  @moduledoc """
  Runs a full or incremental sync of a CalDAV calendar integration.

  ## Sync Tiers

  CalDAV servers vary widely in their protocol support. The tier is probed once
  per integration and stored in `caldav_sync_tier`:

  - **Tier 1** – Server supports `DAV:sync-token` (RFC 6578). A path with no
    token reads the current one as a property and fetches the sync window in
    full; from then on, a sync-collection REPORT carrying that token returns
    just the delta since that point.

  - **Tier 2** – Server supports `cs:getctag` (Apple/Sabre extension). A
    lightweight PROPFIND checks whether the CTag has changed, skipping the
    event fetch entirely when the calendar is unchanged.

  - **Tier 3** – Fallback: a full PROPFIND + REPORT calendar-query on every
    run. Required for basic servers supporting neither extension.

  Tiers 1 and 2 are scoped to a single collection, so each configured calendar
  path runs the tier's mechanism on its own, against its own entry in
  `caldav_sync_tokens`.

  The tier is chosen from what the server *advertises*, and some servers
  advertise `sync-collection` and then refuse every REPORT that uses it. A
  refusal on any path therefore demotes the integration to the best tier that
  does not need the extension, so a lying server costs one request rather than
  every sync.
  The daily forced full fetch clears the stored tier, so detection runs again
  and a server that refused once because it was genuinely unwell gets its delta
  sync back within a day.

  ## Reporting rather than deciding

  Outcomes that need an operator- or owner-facing decision are *reported*, not
  acted on here: `{:error, :unauthorized}`, `{:error, :forbidden}` and
  `{:error, :booking_calendar_missing}` all travel back to the caller. Whether
  those mean "flag the integration and stop retrying" or something else is a
  job-scheduling policy question, and lives with the Oban worker that asked for
  the sync.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalDAV.Errors
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

  Passing `force_full_fetch?: true` skips tier handling entirely: a plain
  calendar-query REPORT runs against every configured path, then every sync
  token is reset and the full-sync timestamp recorded.
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

  # Runs a calendar-query REPORT against every configured path, ignoring the
  # tier, then resets the sync tokens and records the full-sync timestamp.
  #
  # Tier 1 delta sync and Tier 2 CTag checks can silently miss events that were
  # already on the server when the initial sync ran, so a plain calendar-query
  # REPORT is the only way to re-establish ground truth. Clearing every path's
  # sync token makes the next normal sync rebuild its state from scratch, which
  # can self-heal a server whose own sync tracking has drifted; clearing them
  # path by path would leave the rest to carry the drift on. Clearing the tier
  # forces re-detection, which is otherwise one-shot and would never notice a
  # server upgrade that adds sync-collection support.
  @spec forced_full_fetch(struct(), map()) :: result()
  defp forced_full_fetch(integration, client) do
    case EventFetch.fetch_paths(integration, client) do
      :ok ->
        # EventFetch has already stamped per-path state; this final write
        # takes precedence and carries the force-specific columns.
        State.put(integration,
          clear_sync_tokens: true,
          last_full_sync_at: DateTime.utc_now(:second),
          sync_tier: nil
        )

        Logger.info("CalDAV forced full fetch completed",
          calendar_integration_id: integration.id,
          paths: length(client.calendar_paths)
        )

        :ok

      {:error, reason} = error ->
        log_sync_error(integration, "forced full fetch", reason)
        error
    end
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
  defp dispatch(integration, client, _tier), do: EventFetch.fetch_paths(integration, client)

  # ---------------------------------------------------------------------------
  # Tier 1: sync-collection REPORT (delta sync via DAV:sync-token)
  # ---------------------------------------------------------------------------

  defp tier1(integration, client) do
    case EventFetch.each_path(integration, client, &tier1_path(integration, client, &1)) do
      {:error, {:sync_collection_refused, reason}} ->
        demote_from_tier1(integration, client, reason)

      result ->
        result
    end
  end

  defp tier1_path(integration, client, path) do
    calendar_url = UrlBuilder.build_calendar_url(client.base_url, path)

    case State.sync_token(integration, path) do
      nil -> tier1_initial(integration, client, path, calendar_url)
      sync_token -> tier1_delta(integration, client, path, calendar_url, sync_token)
    end
  end

  # A path with no token yet: after the upgrade that introduced per-path
  # tokens, on a newly selected calendar, after a 410, and on every path after
  # the daily forced full fetch clears them all. A path whose delta was too
  # large to read restarts here too, with its old token still stored. The
  # initial sync-collection REPORT RFC 6578 offers for this returns the
  # collection's entire history with every event body inline and no time
  # range, which on a large calendar is enough to take the node down, and the
  # token it would have produced is only stored after processing, so the same
  # request then repeats every cycle. Reading the token as a property and fetching the sync window costs
  # the same as a Tier 3 run.
  #
  # The token is read *before* the fetch. A change made while the fetch runs
  # is then newer than the token and comes back in the next delta, where
  # applying it again is harmless; read afterwards, that change would be
  # skipped for good.
  defp tier1_initial(integration, client, path, calendar_url) do
    case SyncCollectionReport.fetch_sync_token(calendar_url, client) do
      {:ok, sync_token} ->
        EventFetch.fetch_path(integration, client, path, new_sync_token: sync_token)

      {:error, :not_found} ->
        :not_found

      {:error, reason} when reason in [:unauthorized, :forbidden] ->
        {:error, reason}

      # The token is an optimisation: without one the path still syncs in
      # full and asks again next cycle.
      {:error, reason} ->
        log_sync_error(integration, "Tier 1 sync token probe", reason)
        EventFetch.fetch_path(integration, client, path, [])
    end
  end

  defp tier1_delta(integration, client, path, calendar_url, sync_token) do
    case SyncCollectionReport.fetch(client, calendar_url, sync_token) do
      {:ok, {events, deleted_hrefs, new_sync_token}} ->
        Logger.info("CalDAV Tier 1 sync fetched changes",
          calendar_integration_id: integration.id,
          calendar_path: path,
          changed_count: length(events),
          deleted_count: length(deleted_hrefs)
        )

        apply_tier1_delta(integration, path, events, deleted_hrefs, new_sync_token)

      {:error, :sync_token_expired} ->
        Logger.info("CalDAV sync token expired; falling back to full fetch",
          calendar_integration_id: integration.id,
          calendar_path: path
        )

        # Cleared first, so a failed restart leaves the path tokenless rather
        # than holding a token the server has already refused.
        State.put(integration, sync_token: {path, nil})
        tier1_initial(integration, client, path, calendar_url)

      # The server named the changed resources but did not inline their
      # calendar data, so the delta cannot be applied on its own. The token is
      # deliberately kept: it stays valid, and the next cycle is offered the
      # same changes again, so nothing is lost if this fetch fails.
      {:error, :calendar_data_withheld} ->
        Logger.info("CalDAV sync-collection returned no event data; falling back to full fetch",
          calendar_integration_id: integration.id,
          calendar_path: path
        )

        EventFetch.fetch_path(integration, client, path, [])

      # A bulk change on the server produced a delta too large to parse, and
      # it was abandoned mid-transfer. Keeping the token would ask for the same
      # delta every cycle until the daily forced full fetch, so the path
      # restarts from a token read now, as a tokenless path does. Nothing is
      # lost: the fetch that follows reads the sync window as it stands, and a
      # change made during it comes back in the next delta. The old token is
      # not cleared first, so a failed restart leaves the path where it was.
      {:error, :response_too_large} ->
        Logger.warning("CalDAV sync-collection delta too large; restarting from a fresh token",
          calendar_integration_id: integration.id,
          calendar_path: path,
          max_delta_bytes: SyncCollectionReport.max_delta_bytes()
        )

        tier1_initial(integration, client, path, calendar_url)

      {:error, :not_found} ->
        :not_found

      {:error, reason} ->
        if Errors.unsupported_request?(reason) do
          {:error, {:sync_collection_refused, reason}}
        else
          log_unless_actionable(integration, "Tier 1 sync", reason)
          {:error, reason}
        end
    end
  end

  # The tier is chosen from what the server *advertises*: `TierDetector` reads
  # the property list and believes it. Some servers advertise `sync-collection`
  # and then refuse every REPORT that uses it — Infomaniak answers 500 — and
  # because the stored tier was never revisited, such an integration retried the
  # same refused request every cycle and synced only on the daily forced full
  # fetch. Weeks of that look exactly like a calendar that has stopped working,
  # because it has.
  #
  # So fall back to the best tier that does not need it, and record the demotion
  # so the rest of the day stops asking. The daily forced full fetch clears the
  # stored tier, so detection runs again tomorrow: a server that refused once
  # because it was genuinely having a bad minute gets its delta sync back within
  # a day, at the cost of one wasted request. That is the right way round —
  # losing delta sync for a day is cheap, and syncing nothing for a fortnight is
  # not.
  #
  # A refusal on any one path demotes the whole integration rather than that
  # path alone. The tier is stored per integration, and one awkward calendar on
  # an otherwise capable server then costs the others their delta for a day,
  # which Tier 2's per-path CTag check keeps cheap; what it must never do is
  # fail the sync.
  defp demote_from_tier1(integration, client, reason) do
    {:ok, tier} = TierDetector.detect_without_sync_collection(integration, client)

    Logger.warning("CalDAV server refused sync-collection it advertised; falling back",
      calendar_integration_id: integration.id,
      error: inspect(reason),
      tier: tier
    )

    integration
    |> State.put_tier(tier)
    |> dispatch(client, tier)
  end

  defp apply_tier1_delta(integration, path, events, deleted_hrefs, new_sync_token) do
    case SyncReconciler.process_tier1(integration, events, deleted_hrefs) do
      :ok ->
        State.put(integration, sync_token: {path, new_sync_token})
        :ok

      {:error, reason} ->
        Logger.error("CalDAV Tier 1 event processing failed; sync token NOT updated",
          calendar_integration_id: integration.id,
          calendar_path: path,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Tier 2: getctag check + conditional full fetch
  # ---------------------------------------------------------------------------

  defp tier2(integration, client) do
    EventFetch.each_path(integration, client, &tier2_path(integration, client, &1))
  end

  defp tier2_path(integration, client, path) do
    calendar_url = UrlBuilder.build_calendar_url(client.base_url, path)

    case SyncCollectionReport.fetch_ctag(calendar_url, client) do
      {:ok, current_ctag} ->
        ctag_result(integration, client, path, current_ctag)

      {:error, :not_found} ->
        :not_found

      {:error, reason} when reason in [:unauthorized, :forbidden] ->
        {:error, reason}

      {:error, reason} ->
        # A CTag probe is an optimisation, not the sync itself: if it fails for
        # any reason short of auth or a missing collection, fetching everything
        # still produces a correct result.
        log_sync_error(integration, "Tier 2 CTag check", reason)
        EventFetch.fetch_path(integration, client, path, [])
    end
  end

  defp ctag_result(integration, client, path, current_ctag) do
    stored_ctag = State.sync_token(integration, path)

    if current_ctag == stored_ctag and not is_nil(stored_ctag) do
      Logger.debug("CalDAV CTag unchanged; skipping event fetch",
        calendar_integration_id: integration.id,
        calendar_path: path
      )

      State.put(integration, [])
      :ok
    else
      EventFetch.fetch_path(integration, client, path, new_ctag: current_ctag)
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
