defmodule Tymeslot.Integrations.Calendar.CalDAV.TierDetector do
  @moduledoc """
  Probes a CalDAV server to determine which sync extension it supports.

  Returns `{:ok, 1 | 2 | 3}` where:

  - **1** – Server supports `DAV:sync-token` (RFC 6578 delta sync)
  - **2** – Server supports `cs:getctag` (Apple/Sabre CTag extension)
  - **3** – Fallback: no extensions detected
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalDAV.Http, as: CalDAVHttp
  alias Tymeslot.Integrations.Calendar.CalDAV.UrlBuilder
  alias Tymeslot.Integrations.Calendar.CalDAV.XmlHandler

  @doc """
  Probes the server and returns `{:ok, tier}` or `{:error, reason}`.

  When no calendar path is configured, defaults to Tier 3 without making any
  HTTP requests.
  """
  @spec detect(integration :: map(), client :: map()) ::
          {:ok, 1 | 2 | 3} | {:error, :unauthorized | :forbidden | term()}
  def detect(integration, client) do
    primary_path =
      client
      |> Map.get(:calendar_paths, [])
      |> List.first()

    if is_nil(primary_path) do
      {:ok, 3}
    else
      calendar_url = UrlBuilder.build_calendar_url(client.base_url, primary_path)
      probe_sync_token(integration, calendar_url, client)
    end
  end

  @doc false
  @spec xml_contains_sync_token?(binary() | any()) :: boolean()
  def xml_contains_sync_token?(xml_body) when is_binary(xml_body) do
    Regex.match?(~r/<[^>]*sync-token[^>]*>/i, xml_body) or
      Regex.match?(~r/<[^>]*sync-collection[^>]*>/i, xml_body)
  end

  def xml_contains_sync_token?(_other), do: false

  @doc false
  @spec xml_contains_ctag?(binary() | any()) :: boolean()
  def xml_contains_ctag?(xml_body) when is_binary(xml_body) do
    String.contains?(xml_body, "getctag")
  end

  def xml_contains_ctag?(_other), do: false

  @doc """
  Picks the best tier for a server that cannot serve `sync-collection`, even
  though its property list said it could.

  Costs the one CTag PROPFIND that `detect/2` would have made anyway had the
  advertisement been absent, and answers 2 when the server supports `getctag`
  and 3 otherwise. Worth asking rather than dropping straight to 3: tier 2
  skips the event fetch entirely while the calendar is unchanged, and a server
  being demoted here is one already struggling to answer.
  """
  @spec detect_without_sync_collection(struct(), map()) :: {:ok, 2 | 3}
  def detect_without_sync_collection(_integration, client) do
    case client |> Map.get(:calendar_paths, []) |> List.first() do
      nil -> {:ok, 3}
      path -> probe_ctag(UrlBuilder.build_calendar_url(client.base_url, path), client)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp probe_sync_token(integration, calendar_url, client) do
    body = XmlHandler.build_propfind_request(properties: [:supported_report_set, :sync_token])

    case CalDAVHttp.propfind(calendar_url, client.username, client.password,
           body: body,
           depth: "0"
         ) do
      {:ok, %Req.Response{body: xml}} ->
        determine_tier_from_response(xml, calendar_url, client)

      {:error, :unauthorized} ->
        {:error, :unauthorized}

      {:error, :forbidden} ->
        {:error, :forbidden}

      {:error, reason} ->
        Logger.debug("CalDAV tier detection PROPFIND failed, defaulting to Tier 3",
          calendar_integration_id: integration.id,
          reason: inspect(reason)
        )

        {:ok, 3}
    end
  end

  defp determine_tier_from_response(xml_body, calendar_url, client) do
    if xml_contains_sync_token?(xml_body) do
      {:ok, 1}
    else
      probe_ctag(calendar_url, client)
    end
  end

  defp probe_ctag(calendar_url, client) do
    case CalDAVHttp.propfind_ctag(calendar_url, client.username, client.password) do
      {:ok, %Req.Response{body: ctag_xml}} ->
        if xml_contains_ctag?(ctag_xml), do: {:ok, 2}, else: {:ok, 3}

      {:error, _reason} ->
        {:ok, 3}
    end
  end
end
