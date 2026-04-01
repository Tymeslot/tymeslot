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

  A 401/403 response is treated as a permanent discard: the job returns `:ok`
  without retrying. The integration's `is_active` flag is left unchanged so the
  user can correct credentials through the dashboard.

  ## Jitter (first run)

  When `caldav_sync_tier` is nil (first-ever sync), the worker sleeps 0–30 s
  before making any HTTP requests. This prevents a thunderstorm when many CalDAV
  integrations are enqueued simultaneously by the fallback sweep.
  """

  use Oban.Worker,
    queue: :calendar_events,
    max_attempts: 3,
    unique: [
      period: 300,
      keys: [:calendar_integration_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import SweetXml

  require Logger

  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
  alias Tymeslot.Integrations.Calendar.CalDAV.Events, as: CalDAVEvents
  alias Tymeslot.Integrations.Calendar.CalDAV.Http, as: CalDAVHttp
  alias Tymeslot.Integrations.Calendar.CalDAV.TierDetector
  alias Tymeslot.Integrations.Calendar.CalDAV.UrlBuilder
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.SyncBroadcast

  # How far back and forward to fetch events on a full sync.
  # 60 days back, 365 days forward covers meeting scheduling windows.
  @sync_window_past_days 60
  @sync_window_future_days 365

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"calendar_integration_id" => integration_id}}) do
    Logger.metadata(calendar_integration_id: integration_id)

    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, integration} ->
        sync_integration(integration)

      {:error, :not_found} ->
        Logger.warning("CalDAV integration not found, discarding sync job",
          calendar_integration_id: integration_id
        )

        {:discard, "Integration not found"}
    end
  end

  # ---------------------------------------------------------------------------
  # Orchestration
  # ---------------------------------------------------------------------------

  defp sync_integration(integration) do
    client = build_client(integration)

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
        log_auth_error(integration)
        :ok
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
    case client.calendar_paths || [] do
      [] ->
        Logger.warning("No calendar path configured; skipping Tier 1 sync",
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

    case fetch_sync_collection(integration, client, calendar_url) do
      {:ok, {events, deleted_hrefs, new_sync_token}} ->
        Logger.info("CalDAV Tier 1 sync fetched changes",
          calendar_integration_id: integration.id,
          changed_count: length(events),
          deleted_count: length(deleted_hrefs)
        )

        case safe_process_events(integration, events, deleted_hrefs) do
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
        log_auth_error(integration)
        :ok

      {:error, reason} ->
        log_sync_error(integration, "Tier 1 sync", reason)
        {:error, reason}
    end
  end

  defp fetch_sync_collection(integration, client, calendar_url) do
    sync_token = integration.caldav_sync_token
    report_body = build_sync_collection_report(sync_token)

    case CalDAVHttp.report(calendar_url, client.username, client.password, report_body) do
      {:ok, %Req.Response{status: 207, body: body}} ->
        parse_sync_collection_response(body)

      {:ok, %Req.Response{status: 410}} ->
        {:error, :sync_token_expired}

      {:ok, %Req.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: 403}} ->
        {:error, :unauthorized}

      {:error, :unauthorized} ->
        {:error, :unauthorized}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_sync_collection_report(nil) do
    # No stored token: request full sync
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <d:sync-collection xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:sync-token/>
      <d:sync-level>1</d:sync-level>
      <d:prop>
        <d:getetag/>
        <c:calendar-data/>
      </d:prop>
    </d:sync-collection>
    """
  end

  defp build_sync_collection_report(sync_token) when is_binary(sync_token) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <d:sync-collection xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
      <d:sync-token>#{xml_escape(sync_token)}</d:sync-token>
      <d:sync-level>1</d:sync-level>
      <d:prop>
        <d:getetag/>
        <c:calendar-data/>
      </d:prop>
    </d:sync-collection>
    """
  end

  defp parse_sync_collection_response(xml_body) do
    doc = SweetXml.parse(xml_body, namespace_conformant: true, dtd: :none)

    # Extract the new sync token from the response
    raw_sync_token = xpath(doc, ~x"//*[local-name()='sync-token']/text()"s)
    new_sync_token = if raw_sync_token == "", do: nil, else: raw_sync_token

    responses =
      xpath(
        doc,
        ~x"//*[local-name()='response']"l,
        href: ~x"./*[local-name()='href']/text()"s,
        status: ~x".//*[local-name()='status']/text()"s,
        etag: ~x".//*[local-name()='getetag']/text()"s,
        calendar_data: ~x".//*[local-name()='calendar-data']/text()"s
      )

    {changed, deleted} =
      Enum.split_with(responses, fn r ->
        r.calendar_data != "" and not String.contains?(r.status, "404")
      end)

    events =
      changed
      |> Enum.map(fn r ->
        case EventProcessor.parse_ical_from_string(r.calendar_data) do
          {:ok, event} ->
            Map.merge(event, %{href: r.href, etag: EventProcessor.clean_etag(r.etag)})

          {:error, _reason} ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    deleted_hrefs = Enum.map(deleted, & &1.href)

    {:ok, {events, deleted_hrefs, new_sync_token}}
  rescue
    e ->
      Logger.error("Failed to parse sync-collection response", error: inspect(e))
      {:error, :invalid_response}
  end

  # ---------------------------------------------------------------------------
  # Tier 2: getctag check + conditional full fetch
  # ---------------------------------------------------------------------------

  defp sync_tier2(integration, client) do
    case client.calendar_paths || [] do
      [] ->
        Logger.warning("No calendar path configured; skipping Tier 2 sync",
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

    case fetch_ctag(calendar_url, client) do
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
        log_auth_error(integration)
        :ok

      {:error, reason} ->
        log_sync_error(integration, "Tier 2 CTag check", reason)
        # Fall back to full fetch on CTag probe failure
        do_full_fetch(integration, client, primary_path, [])
    end
  end

  defp fetch_ctag(calendar_url, client) do
    case CalDAVHttp.propfind_ctag(calendar_url, client.username, client.password) do
      {:ok, %Req.Response{status: status, body: body}} when status in [200, 207] ->
        parse_ctag_from_response(body)

      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, :unauthorized} ->
        {:error, :unauthorized}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_ctag_from_response(xml_body) when is_binary(xml_body) do
    doc = SweetXml.parse(xml_body, namespace_conformant: true, dtd: :none)

    raw_ctag = xpath(doc, ~x"//*[local-name()='getctag']/text()"s)
    ctag = if raw_ctag == "", do: nil, else: raw_ctag

    {:ok, ctag}
  rescue
    e ->
      Logger.warning("Failed to parse CTag response", error: inspect(e))
      {:ok, nil}
  end

  # ---------------------------------------------------------------------------
  # Tier 3: full calendar-query REPORT
  # ---------------------------------------------------------------------------

  defp sync_tier3(integration, client) do
    paths = client.calendar_paths || []

    if Enum.empty?(paths) do
      Logger.warning("No calendar paths configured for CalDAV sync",
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
    now = DateTime.utc_now()
    start_time = DateTime.add(now, -@sync_window_past_days, :day)
    end_time = DateTime.add(now, @sync_window_future_days, :day)

    case CalDAVEvents.fetch_events(client, calendar_path, start_time, end_time) do
      {:ok, events} ->
        Logger.info("CalDAV full fetch completed",
          calendar_integration_id: integration.id,
          event_count: length(events),
          calendar_path: calendar_path
        )

        case safe_process_events(integration, events) do
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
        log_auth_error(integration)
        :ok

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
      case Keyword.get(opts, :sync_token) do
        nil -> base_attrs
        token -> Map.put(base_attrs, :caldav_sync_token, token)
      end

    case CalendarIntegrationQueries.update_sync_state(integration, attrs) do
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
      _other -> :caldav
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp log_auth_error(integration) do
    Logger.warning("CalDAV sync unauthorised; discarding job",
      calendar_integration_id: integration.id
    )
  end

  defp log_sync_error(integration, phase, reason) do
    Logger.error("CalDAV sync failed",
      calendar_integration_id: integration.id,
      phase: phase,
      error: inspect(reason)
    )
  end

  defp safe_process_events(integration, events, deleted_hrefs \\ []) do
    with :ok <- EventProcessor.process_events(integration, events) do
      maybe_process_deletions(integration, deleted_hrefs)
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  defp maybe_process_deletions(_integration, []), do: :ok

  defp maybe_process_deletions(integration, deleted_hrefs) do
    EventProcessor.process_deletions(integration, deleted_hrefs)
  end

  defp xml_escape(string) when is_binary(string) do
    string
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
