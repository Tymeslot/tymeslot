defmodule Tymeslot.Integrations.Calendar.CalDAV.SyncCollectionReport do
  @moduledoc """
  Builds, sends, and parses RFC 6578 sync-collection REPORTs.

  A sync-collection REPORT is the mechanism behind Tier 1 CalDAV sync: the
  client sends a stored `DAV:sync-token` and the server returns only the
  events that changed since that token was issued.

  This module also provides `fetch_ctag/2` for Tier 2 CTag-based change
  detection — a lightweight PROPFIND that checks whether the calendar has
  changed since the last sync.
  """

  import SweetXml

  require Logger

  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
  alias Tymeslot.Integrations.Calendar.CalDAV.Http, as: CalDAVHttp

  # ---------------------------------------------------------------------------
  # Sync-collection REPORT (Tier 1)
  # ---------------------------------------------------------------------------

  @doc """
  Fetches a sync-collection REPORT from the CalDAV server.

  Uses the integration's stored `caldav_sync_token` to request only
  changes since the last sync. When the token is `nil` a full initial
  sync is requested.

  Returns `{:ok, {events, deleted_hrefs, new_sync_token}}` on success,
  `{:error, :sync_token_expired}` when the server responds with 410 Gone,
  `{:error, :calendar_data_withheld}` when the server reported changes
  without inlining their calendar data (see `parse_response/1`), or
  `{:error, reason}` for other failures.
  """
  @spec fetch(map(), map(), String.t()) ::
          {:ok, {list(map()), list(String.t()), String.t() | nil}}
          | {:error, term()}
  def fetch(integration, client, calendar_url) do
    sync_token = integration.caldav_sync_token
    report_body = build_report(sync_token)

    # RFC 6578, Section 3.2: the sync-collection report is defined only for
    # `Depth: 0`, and a compliant server answers any other value with 400. The
    # scope the client wants travels in `<d:sync-level>`, which `build_report/1`
    # already sends. A 410 answers a token the server no longer recognises, so
    # it means something here that it does not mean on a calendar-query.
    case CalDAVHttp.report(calendar_url, client.username, client.password, report_body,
           depth: "0",
           status_overrides: %{410 => :sync_token_expired}
         ) do
      {:ok, %Req.Response{status: 207, body: body}} ->
        parse_response(body)

      # Some servers answer with plain 200 instead of the mandated 207
      # Multi-Status. The body is a multistatus document either way.
      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("CalDAV sync-collection REPORT returned unexpected status",
          status: status,
          expected: 207
        )

        parse_response(body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Builds a sync-collection REPORT XML body.

  When `sync_token` is `nil`, requests a full initial sync. When a token
  is provided, requests only the delta since that token.
  """
  @spec build_report(String.t() | nil) :: String.t()
  def build_report(nil) do
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

  def build_report(sync_token) when is_binary(sync_token) do
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

  @doc """
  Parses a 207 Multi-Status sync-collection response body.

  Separates changed events (carrying calendar data) from removed resources
  and extracts the new sync token.

  A resource counts as removed only when the server says so, with a 404 on
  the `response` element itself — the signal RFC 6578, Section 3.2 defines
  for a member that left the collection. Missing calendar data is
  deliberately *not* read as a removal: a server is free to answer with the
  etag alone, or to report the data property in its own 404 `propstat`
  because it declines to inline it, and RFC 6578 expects the client to fetch
  those resources separately. Inferring deletion from an absent property
  would hand `SyncReconciler` a list of live events to delete, and a
  deletion auto-cancels the linked meeting and emails both parties — with no
  bulk-deletion circuit breaker on this path, unlike the full fetch.

  So a response that is neither a removal nor a carrier of calendar data
  fails the whole delta with `{:error, :calendar_data_withheld}`, rather than
  being applied in part or read as a deletion: the caller falls back
  to a full fetch, which reads the calendar authoritatively and reconciles
  deletions behind that circuit breaker. The stored sync token is left
  untouched, so the same changes are offered again next cycle.
  """
  @spec parse_response(String.t()) ::
          {:ok, {list(map()), list(String.t()), String.t() | nil}}
          | {:error, :invalid_response | :calendar_data_withheld}
  def parse_response(xml_body) do
    doc = SweetXml.parse(xml_body, namespace_conformant: true, dtd: :none)

    # Extract the new sync token from the response
    raw_sync_token = xpath(doc, ~x"//*[local-name()='sync-token']/text()"s)
    new_sync_token = if raw_sync_token == "", do: nil, else: raw_sync_token

    responses =
      xpath(
        doc,
        ~x"//*[local-name()='response']"l,
        href: ~x"./*[local-name()='href']/text()"s,
        status: ~x"./*[local-name()='status']/text()"s,
        etag: ~x".//*[local-name()='getetag']/text()"s,
        calendar_data: ~x".//*[local-name()='calendar-data']/text()"s
      )

    {removed, present} = Enum.split_with(responses, &removed?/1)
    {changed, withheld} = Enum.split_with(present, &(&1.calendar_data != ""))

    if withheld == [] do
      events =
        changed
        |> Enum.map(&parse_event/1)
        |> Enum.reject(&is_nil/1)

      {:ok, {events, Enum.map(removed, & &1.href), new_sync_token}}
    else
      Logger.warning("CalDAV sync-collection response withheld event data",
        withheld_count: length(withheld),
        changed_count: length(changed),
        removed_count: length(removed)
      )

      {:error, :calendar_data_withheld}
    end
  rescue
    e ->
      Logger.error("Failed to parse sync-collection response", error: inspect(e))
      {:error, :invalid_response}
  catch
    :exit, reason ->
      Logger.error("Failed to parse sync-collection response", error: inspect(reason))
      {:error, :invalid_response}
  end

  # A 404 (or 410) on the `response` element itself, not on a nested
  # `propstat`: the latter reports one property the server could not return,
  # which says nothing about the resource still existing.
  defp removed?(%{status: status}) do
    String.contains?(status, "404") or String.contains?(status, "410")
  end

  # An event whose iCalendar body fails to parse is dropped rather than
  # failing the batch: it is malformed at the source, so re-fetching it in
  # full would produce the same result every cycle.
  defp parse_event(response) do
    case EventProcessor.parse_ical_from_string(response.calendar_data) do
      {:ok, event} ->
        Map.merge(event, %{
          href: response.href,
          etag: EventProcessor.clean_etag(response.etag)
        })

      {:error, _reason} ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # CTag fetching (Tier 2)
  # ---------------------------------------------------------------------------

  @doc """
  Fetches the current CTag for a calendar via a lightweight PROPFIND.

  Returns `{:ok, ctag}` where `ctag` may be `nil` if the server does not
  include one. Returns `{:error, reason}` on transport or auth failure.
  """
  @spec fetch_ctag(String.t(), map()) :: {:ok, String.t() | nil} | {:error, term()}
  def fetch_ctag(calendar_url, client) do
    case CalDAVHttp.propfind_ctag(calendar_url, client.username, client.password) do
      {:ok, %Req.Response{status: status, body: body}} when status in [200, 207] ->
        parse_ctag_response(body)

      {:ok, %Req.Response{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %Req.Response{status: 403}} ->
        {:error, :forbidden}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, :unauthorized} ->
        {:error, :unauthorized}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parses the CTag value from a PROPFIND response body.
  """
  @spec parse_ctag_response(String.t()) :: {:ok, String.t() | nil}
  def parse_ctag_response(xml_body) when is_binary(xml_body) do
    doc = SweetXml.parse(xml_body, namespace_conformant: true, dtd: :none)

    raw_ctag = xpath(doc, ~x"//*[local-name()='getctag']/text()"s)
    ctag = if raw_ctag == "", do: nil, else: raw_ctag

    {:ok, ctag}
  rescue
    e ->
      Logger.warning("Failed to parse CTag response", error: inspect(e))
      {:ok, nil}
  catch
    :exit, reason ->
      Logger.warning("Failed to parse CTag response", error: inspect(reason))
      {:ok, nil}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @doc """
  Escapes a string for safe inclusion in XML content.
  """
  @spec xml_escape(String.t()) :: String.t()
  def xml_escape(string) when is_binary(string) do
    string
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
