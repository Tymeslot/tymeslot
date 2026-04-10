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
  or `{:error, reason}` for other failures.
  """
  @spec fetch(map(), map(), String.t()) ::
          {:ok, {list(map()), list(String.t()), String.t() | nil}}
          | {:error, term()}
  def fetch(integration, client, calendar_url) do
    sync_token = integration.caldav_sync_token
    report_body = build_report(sync_token)

    case CalDAVHttp.report(calendar_url, client.username, client.password, report_body) do
      {:ok, %Req.Response{status: 207, body: body}} ->
        parse_response(body)

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

  Separates changed events (with calendar data) from deleted resources
  (404 status or empty calendar data) and extracts the new sync token.
  """
  @spec parse_response(String.t()) ::
          {:ok, {list(map()), list(String.t()), String.t() | nil}}
          | {:error, :invalid_response}
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
