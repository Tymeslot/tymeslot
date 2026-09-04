defmodule Tymeslot.ExchangeCase do
  @moduledoc """
  Shared ExUnit case template for Exchange (EWS) tests.

  Carries the scaffolding an EWS test otherwise rebuilds: a provider config, a
  one-shot response stub, and the envelopes a server answers with.

  The transport setup is not its own: it comes from
  `Tymeslot.HttpTransportCase`, which installs the real HTTPClient so tests
  exercise the full Req → Req.Test path. What is specific to Exchange, and so
  what justifies a separate template, is the SOAP fixtures below.

  `Tymeslot.MockCase` is not an alternative: it stubs `HTTPClientMock`, so
  nothing below `Config.http_client_module/0` runs and the SSRF, redirect and
  response-cap behaviour the real client provides cannot be observed.

  ## Usage

      defmodule MyExchangeTest do
        use Tymeslot.ExchangeCase

        test "…" do
          respond_with(200, ok_envelope())

          assert {:ok, _doc} = Client.call(config(), "<m:FindFolder/>")
        end
      end
  """

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker

  @types_ns "http://schemas.microsoft.com/exchange/services/2006/types"
  @messages_ns "http://schemas.microsoft.com/exchange/services/2006/messages"
  @soap_ns "http://schemas.xmlsoap.org/soap/envelope/"

  # A well-formed on-premises EWS endpoint, as `Exchange.Provider` builds one.
  @config %{
    base_url: "https://mail.example.com/EWS/Exchange.asmx",
    username: "user@example.com",
    password: "secret",
    verify_ssl: true
  }

  # A synthetic stand-in used wherever a test has to prove a password did not
  # reach an error term or a log line: distinctive enough that a match cannot
  # be a coincidence, and nowhere near a real credential.
  @leak_canary "corr3ct-horse-batt3ry-staple"

  defmacro __using__(opts) do
    async = Keyword.get(opts, :async, false)

    quote do
      # Threading async: through explicitly matters: dropping it would silently
      # downgrade every `use Tymeslot.ExchangeCase, async: true` to async: false.
      use Tymeslot.HttpTransportCase, async: unquote(async)

      import Tymeslot.ExchangeCase

      setup do
        reset_breaker()
        :ok
      end
    end
  end

  @doc """
  Clears the circuit breaker `Exchange.Client` keys by `url`'s host.

  Every EWS request runs through it, so a test that stubs a run of transport
  failures leaves that host's breaker open and the *next* test is answered
  `{:error, :circuit_open}` instead of whatever it stubbed. Called for the
  shared config host by this template's own `setup`; a test working against a
  different base URL calls it again with that URL.

  Scoped to one host rather than `reset_all_hosts/0` so a concurrently running
  test of another provider is left alone. The provider-level breaker is reset
  too, since that is the one a base URL with no parseable host falls back to.
  """
  @spec reset_breaker(String.t()) :: :ok
  def reset_breaker(url \\ @config.base_url) do
    CalendarCircuitBreaker.reset_for_url(:exchange, url)
    CalendarCircuitBreaker.reset(:exchange)
    :ok
  end

  @doc """
  A provider config, with `overrides` (a map or keyword list) merged over it.
  """
  @spec config(map() | keyword()) :: map()
  def config(overrides \\ %{}), do: Map.merge(@config, Map.new(overrides))

  @doc "The password stand-in a leak assertion looks for."
  @spec leak_canary() :: String.t()
  def leak_canary, do: @leak_canary

  @doc """
  Answers every request with `status` and `body`, as XML.
  """
  @spec respond_with(pos_integer(), String.t()) :: :ok
  def respond_with(status, body) do
    ReqTest.stub(:tymeslot_http, fn conn ->
      conn
      |> Conn.put_resp_content_type("text/xml")
      |> Conn.resp(status, body)
    end)
  end

  @doc """
  Wraps a response fragment in the SOAP envelope a server answers with, with
  the EWS prefixes declared on the envelope rather than on the payload.
  """
  @spec soap_envelope(String.t()) :: String.t()
  def soap_envelope(body) do
    """
    <?xml version="1.0" encoding="utf-8"?>
    <s:Envelope xmlns:s="#{@soap_ns}" xmlns:t="#{@types_ns}" xmlns:m="#{@messages_ns}">
      <s:Body>#{body}</s:Body>
    </s:Envelope>
    """
  end

  @doc """
  A successful response to `operation` (`"FindFolder"`, `"FindItem"`, …),
  carrying `payload` inside its single response message.

  Every EWS read answers in this shape, so a test naming its operation and its
  payload has said everything that distinguishes its fixture from the next
  one's.
  """
  @spec response_envelope(String.t(), String.t()) :: String.t()
  def response_envelope(operation, payload \\ "") do
    soap_envelope("""
    <m:#{operation}Response>
        <m:ResponseMessages>
          <m:#{operation}ResponseMessage ResponseClass="Success">
            <m:ResponseCode>NoError</m:ResponseCode>
            #{payload}
          </m:#{operation}ResponseMessage>
        </m:ResponseMessages>
      </m:#{operation}Response>
    """)
  end

  @doc """
  The shortest successful response there is, for tests that need the transport
  to succeed and do not care what it returned.
  """
  @spec ok_envelope() :: String.t()
  def ok_envelope, do: response_envelope("FindFolder")

  @doc """
  The `t:TimeWindow` a `GetUserAvailability` request asked for.

  Shared rather than local to one test because the availability read is sliced
  into a request per chunk of the window (see `Exchange.Provider`), so a stub
  answering it has to know which slice it is looking at, and an assertion on
  the slicing has to read the same bounds.

  The bounds are unqualified local times read in the request's own
  `t:TimeZone`, which names UTC, so they come back as UTC datetimes.
  """
  @spec requested_availability_window(String.t()) :: {DateTime.t(), DateTime.t()}
  def requested_availability_window(request_body) do
    {availability_bound(request_body, "StartTime"), availability_bound(request_body, "EndTime")}
  end

  defp availability_bound(request_body, element) do
    [_match, value] = Regex.run(~r|<t:#{element}>([^<]+)</t:#{element}>|, request_body)

    value |> NaiveDateTime.from_iso8601!() |> DateTime.from_naive!("Etc/UTC")
  end

  @doc "A SOAP fault carrying `message` as its `faultstring`."
  @spec fault_envelope(String.t()) :: String.t()
  def fault_envelope(message) do
    soap_envelope("""
    <s:Fault>
        <faultcode>s:Server</faultcode>
        <faultstring>#{message}</faultstring>
      </s:Fault>
    """)
  end
end
