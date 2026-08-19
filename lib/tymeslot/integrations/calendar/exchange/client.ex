defmodule Tymeslot.Integrations.Calendar.Exchange.Client do
  @moduledoc """
  EWS transport.

  The only module in the Exchange stack that communicates with the HTTP
  client; everything above it works with parsed documents and typed errors
  rather than `Req.Response` structs, mirroring the boundary
  `Tymeslot.Integrations.Calendar.CalDAV.Http` draws. The error vocabulary is
  that module's too, so a status can only mean one thing across the two
  families and the sync layer needs no per-provider dialect.

  EWS answers a SOAP fault with HTTP 500 as a matter of course (a malformed
  request body produces exactly that), so a 500 is parsed for a fault before
  it is treated as a server error. A fault can also arrive with HTTP 200, so
  every parsed body is checked for one either way.

  Credentials never reach an error term or a log line: the Basic
  authorization header is built here and nothing that carries it is logged,
  and the endpoint is logged as scheme and host only, which drops any userinfo
  a base URL might carry.
  """

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Integrations.Calendar.Exchange.Soap

  require Logger

  @typedoc """
  A provider config as `Exchange.Provider` builds it: an atom-keyed map, with
  `:verify_ssl` and `:request_timeout` optional.
  """
  @type config :: %{
          required(:base_url) => String.t(),
          required(:username) => String.t(),
          required(:password) => String.t(),
          optional(:verify_ssl) => boolean(),
          optional(:request_timeout) => pos_integer(),
          optional(atom()) => term()
        }

  @type error_reason ::
          :unauthorized
          | :forbidden
          | :not_found
          | :timeout
          | :rate_limited
          | :server_error
          | :network_error
          | :malformed_xml
          | {:soap_fault, String.t()}
          | {:unexpected_status, pos_integer()}

  # Statuses whose meaning is fixed, shared verbatim with the CalDAV
  # classifier. Everything else is a 5xx (a server error, or a fault when it
  # is a 500) or falls through to `{:unexpected_status, status}`.
  @status_reasons %{
    401 => :unauthorized,
    403 => :forbidden,
    404 => :not_found,
    408 => :timeout,
    429 => :rate_limited
  }

  # Matches the CalDAV read path. Exchange sync runs in an Oban worker, so no
  # user waits on this, and a mailbox with a busy calendar folder can take a
  # while to answer a CalendarView.
  @default_timeout 30_000

  @doc """
  Sends one EWS operation and returns the parsed response document.

  `body` is the operation element, as `Exchange.Requests` builds it; wrapping
  it in the SOAP envelope is this function's job.
  """
  @spec call(config(), String.t()) :: {:ok, Soap.document()} | {:error, error_reason()}
  def call(%{base_url: url} = config, body) when is_binary(url) do
    envelope = Soap.envelope(body)

    case Config.http_client_module().post(url, envelope, headers(config), options(config)) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        Soap.parse(response_body)

      {:ok, %Req.Response{status: 500, body: response_body}} ->
        soap_fault_or_server_error(response_body)

      {:ok, %Req.Response{status: status}} ->
        status_error(status, url)

      {:error, reason} ->
        transport_error(reason, url)
    end
  end

  # A 500 carrying anything other than a fault is the server failing without
  # saying why in SOAP terms: an IIS or reverse-proxy error page, or an
  # envelope with no fault in it. Both are `:server_error` rather than
  # `:malformed_xml` or `{:unexpected_status, 500}`, because what the caller
  # can act on is the same in either case and the status is what said so.
  defp soap_fault_or_server_error(body) do
    # `log: false`: this body is parsed only to look for a fault, so one that
    # is not XML is the expected shape of a proxy error page rather than an
    # anomaly, and a parse warning would describe a status failure.
    case Soap.parse(body, log: false) do
      {:error, {:soap_fault, _message}} = fault -> fault
      _no_fault -> {:error, :server_error}
    end
  end

  defp status_error(status, _url) when is_map_key(@status_reasons, status),
    do: {:error, Map.fetch!(@status_reasons, status)}

  defp status_error(status, _url) when status >= 500, do: {:error, :server_error}

  # An unmodelled status reaches the operator as a code and nothing else
  # unless it is logged here; the provider collapses every non-auth failure
  # into one user-facing sentence.
  defp status_error(status, url) do
    Logger.warning("Exchange EWS request returned an unhandled status",
      endpoint: loggable_url(url),
      status: status
    )

    {:error, {:unexpected_status, status}}
  end

  defp transport_error(%Mint.TransportError{reason: :timeout}, _url), do: {:error, :timeout}
  defp transport_error(%Req.TransportError{reason: :timeout}, _url), do: {:error, :timeout}
  defp transport_error(%Mint.HTTPError{reason: :timeout}, _url), do: {:error, :timeout}

  defp transport_error(reason, url) do
    Logger.warning("Exchange EWS request failed",
      endpoint: loggable_url(url),
      error: error_label(reason)
    )

    {:error, :network_error}
  end

  # The exception itself is never inspected whole: `SsrfBlockedError` and
  # `ResponseTooLargeError` both carry the request URL, which is the one place
  # a credential could still be hiding. The struct name plus its `:reason`
  # says everything the operator needs and can carry nothing else.
  defp error_label(%module{reason: reason}), do: "#{inspect(module)}: #{inspect(reason)}"
  defp error_label(%module{}), do: inspect(module)

  # Unreachable today: `HTTPClient` returns only exception structs. It stays
  # because without it a non-struct term would raise `FunctionClauseError` from
  # inside the error handler itself, turning a recoverable network failure into
  # an Oban crash.
  defp error_label(other), do: inspect(other)

  defp headers(%{username: username, password: password})
       when is_binary(username) and is_binary(password) do
    [
      {"Authorization", "Basic " <> Base.encode64("#{username}:#{password}")},
      {"Content-Type", "text/xml; charset=utf-8"},
      {"Accept", "text/xml"}
    ]
  end

  defp headers(_config) do
    raise ArgumentError, "Exchange credentials must be non-nil binaries"
  end

  defp options(config) do
    [
      receive_timeout: Map.get(config, :request_timeout, @default_timeout),
      # The EWS endpoint is a URL the user typed, so it gets the same
      # request-time SSRF validation and redirect refusal the CalDAV family
      # gets. An operator whose Exchange server genuinely sits on a private
      # network opts out through `:allow_private_ips_for_calendar`.
      ssrf_protect: true
    ] ++ tls_options(config)
  end

  # `verify_ssl: false` exists for the self-signed certificates on-premises
  # Exchange deployments routinely carry. It is opt-in per integration and
  # defaults to verifying. Nothing is passed at all in the default case:
  # `connect_options` makes Req abandon the shared Finch pool, and that is not
  # a price worth paying to say "verify as you already would".
  defp tls_options(%{verify_ssl: false}),
    do: [connect_options: [transport_opts: [verify: :verify_none]]]

  defp tls_options(_config), do: []

  # Scheme and host only. A configured EWS URL should carry no userinfo, and
  # rebuilding the URL from its parts guarantees that one which does cannot
  # reach the logs.
  defp loggable_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) ->
        "#{scheme}://#{host}"

      _unparseable ->
        "(unparseable url)"
    end
  end
end
