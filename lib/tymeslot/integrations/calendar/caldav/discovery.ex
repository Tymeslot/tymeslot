defmodule Tymeslot.Integrations.Calendar.CalDAV.Discovery do
  @moduledoc """
  CalDAV server and calendar discovery domain.

  Owns the RFC 4791 principal-chasing protocol that locates a user's calendar
  collection on any compliant server — including those where the guessed
  discovery path fails. Also validates URLs for SSRF safety and rate-limits
  discovery operations before any network contact.

  ## Discovery Strategy

  1. Attempts the provider-specific guessed path (e.g., `/calendars/{user}/`).
  2. On `:not_found`, `:forbidden` or `:server_error`, follows the full RFC 4791
     chain:
     - PROPFIND the supplied base URL, then the origin root, until one answers
       with a `current-user-principal` href
     - PROPFIND principal URL → `calendar-home-set` href
     - PROPFIND calendar-home-set → calendar list

  Callers receive `CalendarEntry` structs — never raw HTTP responses, XML, or
  intermediate maps.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalDAV.{Base, Http, UrlBuilder, XmlHandler}
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Security.SsrfGuard
  alias Tymeslot.Security.UrlValidation

  require Logger

  # Errors that mean "this URL was not the right place to ask", so the next
  # probe candidate is worth trying. Deliberately the same trio the callers
  # above already treat as "the guessed path was wrong, fall back".
  #
  # Everything else ends the walk where it stands. `:unauthorized` in
  # particular must not advance: the credentials are wrong, no URL can fix
  # that, and re-presenting a rejected login to a server that locks accounts
  # out makes the user's situation worse rather than better.
  @probe_next_candidate_errors [:not_found, :forbidden, :server_error]

  # SSRF guard for outbound discovery/test-connection PROPFINDs.
  #
  # Mirrors the persistence posture in `CalendarIntegrationSchema`: an
  # authenticated user must not be able to drive server-side requests at
  # internal hosts (169.254.169.254, 10.x, loopback, link-local) during
  # Discover/Test any more than they can save such a URL. Plain HTTP for public
  # hosts is still rejected via `enforce_https_for_public`.
  #
  # `opts[:allow_private_ips]` lets a trusted in-process caller (e.g. the live
  # CalDAV integration test against a local Baikal container) bypass the
  # private-IP block. It otherwise defaults to the operator's
  # `ALLOW_PRIVATE_IPS_FOR_CALENDAR` opt-out (false in production), so every
  # request originating from a user-supplied URL — the only path that matters
  # for SSRF — keeps the same posture as persistence.
  defp url_validation_opts(opts) do
    base = [enforce_https_for_public: true, block_private_ips: true]

    allow_private = Keyword.get(opts, :allow_private_ips, SsrfGuard.allow_private_for_calendar?())

    if allow_private do
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

  Pure I/O: rate limiting the connection test is the caller's job
  (`Tymeslot.Integrations.Calendar.Connection.test_connection/2`), not this
  module's — charging a token here as well as there would tax one click twice.
  """
  @spec test_connection(Base.client(), keyword()) ::
          {:ok, String.t()} | {:error, Base.error_reason()}
  def test_connection(client, opts \\ []) do
    with :ok <- UrlValidation.validate_http_url(client.base_url, url_validation_opts(opts)) do
      discovery_url = UrlBuilder.build_discovery_url(client)

      result =
        case Http.propfind(discovery_url, client.username, client.password,
               depth: "0",
               max_retries: 0
             ) do
          {:ok, %Req.Response{}} ->
            :ok

          {:error, reason} when reason in [:not_found, :forbidden, :server_error] ->
            Logger.debug(
              "CalDAV discovery path unavailable; verifying via full RFC 4791 discovery",
              reason: reason,
              base_url: client.base_url
            )

            # Run the complete principal → calendar-home-set → calendar-list
            # chain rather than a credentials-only probe, so a passing test
            # proves calendars are actually reachable. iCloud's principal probe
            # returns 207 even when the guessed path 403s, so a probe that
            # stopped at `current-user-principal` reported success on a
            # connection that could not list any calendars.
            case discover_via_rfc4791(client) do
              {:ok, _calendars} -> :ok
              {:error, _reason} = error -> error
            end

          {:error, _reason} = error ->
            error
        end

      normalise_test_result(result, client)
    end
  end

  # Radicale returns 403 for auth failures; re-tag so callers treat it as a
  # credential error rather than a permissions error. Every other error passes
  # through unchanged.
  defp normalise_test_result(:ok, _client),
    do: {:ok, dgettext("dashboard_calendar_providers", "CalDAV connection successful")}

  defp normalise_test_result({:error, :forbidden}, %{provider: :radicale}),
    do: {:error, :unauthorized}

  defp normalise_test_result({:error, reason}, _client), do: {:error, reason}

  @doc """
  Discovers available calendars on the CalDAV server.

  Validates the server URL for SSRF safety before any network contact.
  Attempts the guessed discovery path first; on failure follows the full RFC
  4791 principal chain. Returns `CalendarEntry` structs.

  Pure I/O: rate limiting discovery is the caller's job
  (`Tymeslot.Integrations.Calendar.Discovery`), not this module's — charging
  a token here as well as there would tax one discovery request twice.
  """
  @spec discover_calendars(Base.client(), keyword()) ::
          {:ok, [CalendarEntry.t()]} | {:error, Base.error_reason()}
  def discover_calendars(client, opts \\ []) do
    with :ok <- UrlValidation.validate_http_url(client.base_url, url_validation_opts(opts)) do
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

  # Full RFC 4791 discovery chain:
  #   1. PROPFIND a probe URL → current-user-principal href
  #   2. PROPFIND principal URL → calendar-home-set href
  #   3. PROPFIND calendar-home-set → calendar list
  defp discover_via_rfc4791(client) do
    with {:ok, principal_href} <- probe_current_user_principal(client) do
      calendars_from_principal(client, principal_href)
    end
  end

  # Where to ask for `current-user-principal`, in order.
  #
  # The URL the account owner supplied is asked first, because it is the only
  # place we have positive evidence a CalDAV server lives. On a server mounted
  # under a subpath (`https://host/caldav/`) it is also the *only* candidate
  # that answers at all — the origin root 404s — which is what made a wrong
  # guessed path unrecoverable there: this fallback existed to rescue a bad
  # guess and opened by discarding the one path the user had actually given
  # us. The origin root stays as the second candidate, for servers that answer
  # at `/` but not at whatever specific collection URL was pasted.
  #
  # A base URL that already *is* the origin root collapses to a single
  # candidate, so the common case costs exactly the requests it did before.
  defp principal_probe_urls(client) do
    as_supplied = String.trim_trailing(client.base_url, "/") <> "/"

    Enum.uniq([as_supplied, UrlBuilder.build_calendar_url(client.base_url, "/")])
  end

  defp probe_current_user_principal(client) do
    probe_principal_candidates(principal_probe_urls(client), client, nil)
  end

  # `first_error` is the failure from the *first* candidate, not the last: that
  # one is about the URL the account owner typed, which is the one they can act
  # on.
  defp probe_principal_candidates([], _client, first_error),
    do: {:error, first_error || :not_found}

  defp probe_principal_candidates([url | rest], client, first_error) do
    case Http.propfind(url, client.username, client.password,
           body: XmlHandler.build_propfind_request(properties: [:current_user_principal]),
           depth: "0"
         ) do
      {:ok, %Req.Response{body: principal_xml}} ->
        case XmlHandler.parse_current_user_principal(principal_xml) do
          {:ok, principal_href} ->
            {:ok, principal_href}

          # A 207 carrying no principal: the server answered, but not about a
          # CalDAV principal. Means the same as a 404 for our purposes.
          {:error, reason} ->
            probe_principal_candidates(rest, client, first_error || reason)
        end

      {:error, reason} when reason in @probe_next_candidate_errors ->
        Logger.debug("CalDAV principal probe found nothing; trying the next candidate",
          reason: reason,
          probe_url: display_url(url)
        )

        probe_principal_candidates(rest, client, first_error || reason)

      {:error, _reason} = error ->
        error
    end
  end

  # Reached only once a principal probe has succeeded, which is itself proof
  # the server accepted the credentials. A missing resource from here on is
  # therefore about where the calendars live rather than who the user is, and
  # is reported as such: a bare `:not_found` sends the account owner back to
  # re-check the credentials already known to be correct.
  defp calendars_from_principal(client, principal_href) do
    principal_url = UrlBuilder.build_calendar_url(client.base_url, principal_href)

    with {:ok, %Req.Response{body: home_xml}} <-
           Http.propfind(principal_url, client.username, client.password,
             body: XmlHandler.build_propfind_request(properties: [:calendar_home_set]),
             depth: "0"
           ),
         {:ok, home_href} <- XmlHandler.parse_calendar_home_set(home_xml),
         home_url = UrlBuilder.build_calendar_url(client.base_url, home_href),
         {:ok, %Req.Response{body: cal_xml}} <-
           Http.propfind(home_url, client.username, client.password) do
      parse_calendar_discovery(cal_xml, client)
    else
      {:error, :not_found} ->
        {:error, {:calendar_home_not_found, display_url(client.base_url)}}

      {:error, _reason} = error ->
        error
    end
  end

  # Never echo a URL's userinfo back to the account owner or into the logs: a
  # password typed into the server-URL field would otherwise ride along in a
  # flash message.
  defp display_url(url) do
    case URI.parse(url) do
      %URI{userinfo: nil} -> url
      parsed -> URI.to_string(%{parsed | userinfo: nil})
    end
  end

  defp parse_calendar_discovery(xml_body, _client) do
    XmlHandler.parse_calendar_discovery(xml_body)
  end

  defp with_discovery_breaker(client, opts, fun) when is_function(fun, 0) do
    provider = Map.get(client, :provider, :caldav)
    host = Base.extract_host_from_url(client.base_url)
    opts = Keyword.put(opts, :host, host)
    CalendarCircuitBreaker.with_breaker(provider, opts, fun)
  end
end
