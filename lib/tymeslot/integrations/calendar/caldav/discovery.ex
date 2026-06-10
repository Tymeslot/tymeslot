defmodule Tymeslot.Integrations.Calendar.CalDAV.Discovery do
  @moduledoc """
  CalDAV server and calendar discovery domain.

  Owns the RFC 4791 principal-chasing protocol that locates a user's calendar
  collection on any compliant server — including those where the guessed
  discovery path fails. Also validates URLs for SSRF safety and rate-limits
  discovery operations before any network contact.

  ## Discovery Strategy

  1. Attempts the provider-specific guessed path (e.g., `/calendars/{user}/`).
  2. On `:not_found` or `:server_error`, follows the full RFC 4791 chain:
     - PROPFIND `/` → `current-user-principal` href
     - PROPFIND principal URL → `calendar-home-set` href
     - PROPFIND calendar-home-set → calendar list

  Callers receive parsed calendar maps — never raw HTTP responses or XML.
  """

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalDAV.{Base, Http, UrlBuilder, XmlHandler}
  alias Tymeslot.Security.{RateLimiter, UrlValidation}

  require Logger

  # SSRF guard for outbound discovery/test-connection PROPFINDs.
  #
  # Mirrors the persistence posture in `CalendarIntegrationSchema` (which
  # validates `:base_url` with `block_private_ips: true`): an authenticated
  # user must not be able to drive server-side requests at internal hosts
  # (169.254.169.254, 10.x, loopback, link-local) during Discover/Test any
  # more than they can save such a URL. Plain HTTP for public hosts is still
  # rejected via `enforce_https_for_public`.
  #
  # `opts[:allow_private_ips]` lets a trusted in-process caller (e.g. the live
  # CalDAV integration test against a local Baikal container) bypass the
  # private-IP block. It defaults to `false`, so every request originating from
  # a user-supplied URL — the only path that matters for SSRF — keeps the same
  # posture as persistence.
  defp url_validation_opts(opts) do
    base = [enforce_https_for_public: true, block_private_ips: true]

    if Keyword.get(opts, :allow_private_ips, false) do
      Keyword.put(base, :block_private_ips, false)
    else
      base
    end
  end

  @doc """
  Tests connectivity to a CalDAV server.

  Attempts to reach the provider-specific discovery path. If it returns
  `:not_found` or `:server_error`, falls back to an RFC 4791
  `current-user-principal` probe which verifies credentials are valid even
  when the guessed path is wrong (e.g., Zimbra).

  Rate-limited per IP to prevent connection-testing abuse.
  """
  @spec test_connection(Base.client(), keyword()) ::
          {:ok, String.t()} | {:error, Base.error_reason()}
  def test_connection(client, opts \\ []) do
    ip_address = Keyword.get(opts, :ip_address, "127.0.0.1")

    with :ok <- check_rate_limit(:connection, ip_address),
         :ok <- UrlValidation.validate_http_url(client.base_url, url_validation_opts(opts)) do
      discovery_url = UrlBuilder.build_discovery_url(client)

      result =
        case Http.propfind(discovery_url, client.username, client.password,
               depth: "0",
               max_retries: 0
             ) do
          {:ok, _response} = success ->
            success

          {:error, reason} when reason in [:not_found, :forbidden, :server_error] ->
            Logger.debug("CalDAV discovery path not found; falling back to RFC 4791 probe",
              reason: reason,
              base_url: client.base_url
            )

            rfc4791_probe(client.base_url, client.username, client.password)

          {:error, _reason} = error ->
            error
        end

      case result do
        {:ok, %Req.Response{}} ->
          {:ok, "CalDAV connection successful"}

        {:error, :unauthorized} ->
          {:error, :unauthorized}

        {:error, :not_found} ->
          {:error, :not_found}

        # Radicale returns 403 for auth failures; re-tag so callers treat it as
        # a credential error rather than a permissions error.
        {:error, :forbidden} when client.provider == :radicale ->
          {:error, :unauthorized}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Discovers available calendars on the CalDAV server.

  Validates the server URL for SSRF safety and enforces rate limits before
  any network contact. Attempts the guessed discovery path first; on failure
  follows the full RFC 4791 principal chain. Returns parsed calendar maps.
  """
  @spec discover_calendars(Base.client(), keyword()) ::
          {:ok, list(map())} | {:error, Base.error_reason()}
  def discover_calendars(client, opts \\ []) do
    ip_address = Keyword.get(opts, :ip_address, "127.0.0.1")

    with :ok <- check_rate_limit(:discovery, ip_address),
         :ok <- UrlValidation.validate_http_url(client.base_url, url_validation_opts(opts)) do
      with_discovery_breaker(client, opts, fn ->
        discovery_url = UrlBuilder.build_discovery_url(client)

        case Http.propfind(discovery_url, client.username, client.password, max_retries: 0) do
          {:ok, %Req.Response{body: body}} ->
            parse_calendar_discovery(body, client)

          {:error, reason} when reason in [:not_found, :forbidden, :server_error] ->
            Logger.debug(
              "CalDAV discovery path not found; falling back to RFC 4791 principal discovery",
              reason: reason,
              base_url: client.base_url
            )

            discover_via_rfc4791(client)

          {:error, reason} ->
            {:error, reason}
        end
      end)
    end
  end

  # Probes the server root for `current-user-principal` to verify that
  # credentials are valid when the guessed discovery path fails.
  # A 207 response here proves credentials work even if the path was wrong.
  defp rfc4791_probe(base_url, username, password) do
    url = UrlBuilder.build_calendar_url(base_url, "/")
    body = XmlHandler.build_propfind_request(properties: [:current_user_principal])
    Http.propfind(url, username, password, body: body, depth: "0")
  end

  # Full RFC 4791 discovery chain:
  #   1. PROPFIND server root → current-user-principal href
  #   2. PROPFIND principal URL → calendar-home-set href
  #   3. PROPFIND calendar-home-set → calendar list
  defp discover_via_rfc4791(client) do
    origin_root = UrlBuilder.build_calendar_url(client.base_url, "/")

    with {:ok, %Req.Response{body: principal_xml}} <-
           Http.propfind(origin_root, client.username, client.password,
             body: XmlHandler.build_propfind_request(properties: [:current_user_principal]),
             depth: "0"
           ),
         {:ok, principal_href} <- XmlHandler.parse_current_user_principal(principal_xml),
         principal_url = UrlBuilder.build_calendar_url(client.base_url, principal_href),
         {:ok, %Req.Response{body: home_xml}} <-
           Http.propfind(principal_url, client.username, client.password,
             body: XmlHandler.build_propfind_request(properties: [:calendar_home_set]),
             depth: "0"
           ),
         {:ok, home_href} <- XmlHandler.parse_calendar_home_set(home_xml) do
      home_url = UrlBuilder.build_calendar_url(client.base_url, home_href)

      case Http.propfind(home_url, client.username, client.password) do
        {:ok, %Req.Response{body: cal_xml}} -> parse_calendar_discovery(cal_xml, client)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp parse_calendar_discovery(xml_body, client) do
    XmlHandler.parse_calendar_discovery(xml_body,
      include_id: true,
      include_selected: false,
      provider: client.provider
    )
  end

  defp with_discovery_breaker(client, opts, fun) when is_function(fun, 0) do
    provider = Map.get(client, :provider, :caldav)
    host = Base.extract_host_from_url(client.base_url)
    opts = Keyword.put(opts, :host, host)
    CalendarCircuitBreaker.with_breaker(provider, opts, fun)
  end

  defp check_rate_limit(:connection, ip_address) do
    case RateLimiter.check_caldav_connection_rate_limit(ip_address) do
      :ok -> :ok
      {:error, :rate_limited, message} -> {:error, message}
    end
  end

  defp check_rate_limit(:discovery, ip_address) do
    case RateLimiter.check_calendar_discovery_rate_limit(ip_address) do
      :ok -> :ok
      {:error, :rate_limited, message} -> {:error, message}
    end
  end
end
