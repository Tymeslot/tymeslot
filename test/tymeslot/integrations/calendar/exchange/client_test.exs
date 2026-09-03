defmodule Tymeslot.Integrations.Calendar.Exchange.ClientTest do
  use Tymeslot.ExchangeCase, async: false

  @moduletag :integrations

  import Mox

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Calendar.Exchange.{Client, Requests, Soap}
  alias Tymeslot.Test.LogCapture

  setup :verify_on_exit!

  describe "call/2 request shape" do
    test "posts the operation inside a SOAP envelope with Basic authentication" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/EWS/Exchange.asmx"

        {:ok, body, conn} = Conn.read_body(conn)

        # The caller hands over an operation fragment; the envelope, the EWS
        # version header and the placement inside soap:Body are this module's
        # responsibility.
        assert body =~ "<soap:Envelope"
        assert body =~ ~s(<t:RequestServerVersion Version="Exchange2013"/>)
        assert body =~ ~r{<soap:Body>\s*<m:FindFolder}

        assert ["Basic " <> encoded] = Conn.get_req_header(conn, "authorization")
        assert Base.decode64!(encoded) == "user@example.com:secret"

        assert ["text/xml; charset=utf-8"] = Conn.get_req_header(conn, "content-type")
        assert ["text/xml"] = Conn.get_req_header(conn, "accept")

        conn
        |> Conn.put_resp_content_type("text/xml")
        |> Conn.resp(200, ok_envelope())
      end)

      assert {:ok, _doc} = Client.call(config(), Requests.find_folder())
    end
  end

  describe "call/2 response" do
    test "returns the parsed response document" do
      respond_with(200, ok_envelope())

      assert {:ok, doc} = Client.call(config(), Requests.find_folder())

      # Proves the returned value is the parsed *response*, not merely some
      # document: a caller can read the response message straight out of it.
      assert [message] = Soap.response_messages(doc, "FindFolderResponseMessage")
      assert Soap.response_code(message) == "NoError"
    end
  end

  describe "call/2 status mapping" do
    test "maps 401 to :unauthorized" do
      respond_with(401, "Unauthorized")

      assert {:error, :unauthorized} = Client.call(config(), "<m:FindFolder/>")
    end

    test "maps 403 to :forbidden" do
      respond_with(403, "Forbidden")

      assert {:error, :forbidden} = Client.call(config(), "<m:FindFolder/>")
    end

    test "maps 404 to :not_found" do
      respond_with(404, "Not Found")

      assert {:error, :not_found} = Client.call(config(), "<m:FindFolder/>")
    end

    test "maps 408 to :timeout" do
      respond_with(408, "Request Timeout")

      assert {:error, :timeout} = Client.call(config(), "<m:FindFolder/>")
    end

    test "maps 429 to :rate_limited" do
      respond_with(429, "Too Many Requests")

      assert {:error, :rate_limited} = Client.call(config(), "<m:FindFolder/>")
    end

    test "maps an unmodelled 4xx to :unexpected_status with the code" do
      respond_with(415, "Unsupported Media Type")

      assert {:error, {:unexpected_status, 415}} = Client.call(config(), "<m:FindFolder/>")
    end

    test "logs the server's own explanation of an unmodelled status" do
      # The code alone does not diagnose one: a 415 covers a dozen causes, and
      # an EWS endpoint behind IIS or a reverse proxy answers with a page
      # saying which.
      LogCapture.attach()

      respond_with(415, "<html><body>The request filtering module is configured</body></html>")

      assert {:error, {:unexpected_status, 415}} = Client.call(config(), "<m:FindFolder/>")

      event = LogCapture.await_log("unhandled status")

      assert LogCapture.user_metadata(event).body =~ "request filtering module"
    end

    test "maps a 5xx that is not a fault to :server_error" do
      respond_with(503, "busy")

      assert {:error, :server_error} = Client.call(config(), "<m:FindFolder/>")
    end

    test "maps a redirect to :unexpected_status rather than following it" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        conn
        |> Conn.put_resp_header("location", "https://login.example.com/adfs")
        |> Conn.resp(302, "")
      end)

      assert {:error, {:unexpected_status, 302}} = Client.call(config(), "<m:FindFolder/>")
    end
  end

  describe "call/2 SOAP faults" do
    test "surfaces a fault returned with HTTP 500" do
      respond_with(500, fault_envelope("Invalid SOAP envelope"))

      assert {:error, {:soap_fault, "Invalid SOAP envelope"}} =
               Client.call(config(), "<m:FindFolder/>")
    end

    test "surfaces a fault returned with HTTP 200" do
      respond_with(200, fault_envelope("The specified folder could not be found"))

      assert {:error, {:soap_fault, "The specified folder could not be found"}} =
               Client.call(config(), "<m:FindFolder/>")
    end

    test "treats a 500 whose body is not a fault as a server error" do
      respond_with(500, "<html><body>Proxy Error</body></html>")

      assert {:error, :server_error} = Client.call(config(), "<m:FindFolder/>")
    end

    test "treats a 500 whose body is not XML at all as a server error" do
      respond_with(500, "Internal Server Error")

      assert {:error, :server_error} = Client.call(config(), "<m:FindFolder/>")
    end

    test "does not report a parse failure for a 500 the status already explains" do
      # A reverse proxy answering 500 with an HTML error page is the common
      # case, and the body is parsed only to look for a fault. Warning about
      # its parseability describes the wrong failure to the operator.
      LogCapture.attach()

      respond_with(500, "<html><body>502 Bad Gateway</body>")

      assert {:error, :server_error} = Client.call(config(), "<m:FindFolder/>")

      messages = Enum.map(LogCapture.drain(), &LogCapture.message_text(&1.msg))
      refute Enum.any?(messages, &(&1 =~ "not parseable XML"))
    end

    test "maps an unparseable 200 body to :malformed_xml" do
      respond_with(200, "<html><body>Sign in")

      assert {:error, :malformed_xml} = Client.call(config(), "<m:FindFolder/>")
    end
  end

  describe "call/2 transport errors" do
    test "maps a transport timeout to :timeout" do
      ReqTest.stub(:tymeslot_http, fn conn -> ReqTest.transport_error(conn, :timeout) end)

      assert {:error, :timeout} = Client.call(config(), "<m:FindFolder/>")
    end

    test "tells a refused certificate apart from a network failure" do
      # An on-premises server behind a self-signed certificate is the ordinary
      # case for this provider, and the connection form carries a toggle for
      # exactly it. Collapsing this into `:network_error` tells the reader to
      # check their network and URL, pointing away from the control that fixes
      # it. The alert shape is the one a self-signed peer actually produces.
      alert =
        {:tls_alert,
         {:bad_certificate, ~c"TLS client: Fatal - Bad Certificate\n selfsigned_peer"}}

      ReqTest.stub(:tymeslot_http, fn conn -> ReqTest.transport_error(conn, alert) end)

      assert {:error, :tls_error} = Client.call(config(), "<m:FindFolder/>")
    end

    test "maps any other transport failure to :network_error" do
      ReqTest.stub(:tymeslot_http, fn conn -> ReqTest.transport_error(conn, :econnrefused) end)

      assert {:error, :network_error} = Client.call(config(), "<m:FindFolder/>")
    end

    test "logs a base URL it cannot parse without raising over it" do
      # What a user typing a host into the EWS field produces. The SSRF guard
      # refuses it, which routes it through the same error handler a refused
      # connection takes, and that handler must survive a URL with no scheme:
      # raising there would turn a recoverable failure into an Oban crash.
      LogCapture.attach()
      with_config(:tymeslot, :environment, :prod)

      ReqTest.stub(:tymeslot_http, fn _conn -> flunk("request must not leave the node") end)

      config = config(base_url: "mail.example.com/EWS/Exchange.asmx")

      assert {:error, :network_error} = Client.call(config, "<m:FindFolder/>")

      logged = Enum.map_join(LogCapture.drain(), "\n", &LogCapture.dump/1)

      assert logged =~ "Exchange EWS request failed"
      assert logged =~ "(unparseable url)"
    end
  end

  describe "call/2 request options" do
    setup do
      # Asserting at the HTTP-client boundary is the only way to observe the
      # TLS and timeout options: Req.Test replaces the adapter, so neither
      # reaches the stub plug.
      with_config(:tymeslot, :http_client_module, HTTPClientMock)
      :ok
    end

    test "verifies certificates and threads SSRF protection by default" do
      expect(HTTPClientMock, :post, fn _url, _body, _headers, opts ->
        refute Keyword.has_key?(opts, :connect_options)
        assert opts[:ssrf_protect] == true
        assert opts[:receive_timeout] == 30_000

        {:ok, %Req.Response{status: 200, body: ok_envelope()}}
      end)

      assert {:ok, _doc} = Client.call(config(), "<m:FindFolder/>")
    end

    test "disables certificate verification only when the integration opts out" do
      expect(HTTPClientMock, :post, fn _url, _body, _headers, opts ->
        assert opts[:connect_options] == [transport_opts: [verify: :verify_none]]

        {:ok, %Req.Response{status: 200, body: ok_envelope()}}
      end)

      assert {:ok, _doc} = Client.call(config(verify_ssl: false), "<m:FindFolder/>")
    end

    test "honours a per-integration request timeout" do
      expect(HTTPClientMock, :post, fn _url, _body, _headers, opts ->
        assert opts[:receive_timeout] == 5_000

        {:ok, %Req.Response{status: 200, body: ok_envelope()}}
      end)

      assert {:ok, _doc} = Client.call(config(request_timeout: 5_000), "<m:FindFolder/>")
    end
  end

  describe "credential handling" do
    @describetag :security

    setup do
      LogCapture.attach(logger_level: :debug)
      :ok
    end

    test "keeps the password out of every error term and every log line" do
      config = config(password: leak_canary())
      encoded = Base.encode64("#{config.username}:#{config.password}")

      failures = [
        fn conn -> Conn.resp(conn, 401, "Unauthorized") end,
        fn conn -> Conn.resp(conn, 415, "Unsupported Media Type") end,
        fn conn -> Conn.resp(conn, 500, "<html><body>Proxy Error") end,
        fn conn -> ReqTest.transport_error(conn, :econnrefused) end
      ]

      for respond <- failures do
        ReqTest.stub(:tymeslot_http, respond)

        assert {:error, reason} = Client.call(config, "<m:FindFolder/>")
        refute inspect(reason) =~ config.password
        refute inspect(reason) =~ encoded
      end

      logged = Enum.map_join(LogCapture.drain(), "\n", &LogCapture.dump/1)

      # Anchors the two refutations below: without this the assertion would
      # pass just as happily over an empty capture.
      assert logged =~ "Exchange"
      refute logged =~ config.password
      refute logged =~ encoded
    end

    test "raises rather than sending a request when a credential is missing" do
      ReqTest.stub(:tymeslot_http, fn _conn ->
        flunk("no request may be sent with an incomplete credential")
      end)

      assert_raise ArgumentError, fn ->
        Client.call(config(password: nil), "<m:FindFolder/>")
      end
    end
  end

  describe "SSRF protection" do
    @describetag :security

    setup do
      LogCapture.attach(logger_level: :debug)
      with_config(:tymeslot, :environment, :prod)
      with_config(:tymeslot, :allow_private_ips_for_calendar, false)
      with_config(:tymeslot, :dns_resolver_module, ExchangeSsrfPrivateResolver)
      :ok
    end

    test "blocks the request when the EWS host resolves to a private address" do
      ReqTest.stub(:tymeslot_http, fn _conn ->
        flunk("network request must not reach the server — ssrf_protect: true is missing")
      end)

      assert {:error, :network_error} =
               Client.call(
                 config(base_url: "https://exchange.corp/EWS/Exchange.asmx"),
                 "<m:FindFolder/>"
               )
    end

    test "logs neither the endpoint's userinfo nor the blocked URL verbatim" do
      # SsrfBlockedError carries the request URL, so this is the one failure
      # that would put a base URL into the logs whole. A base URL should never
      # carry userinfo, but nothing stops one being saved with it.
      config = config(base_url: "https://svc:#{leak_canary()}@exchange.corp/EWS/Exchange.asmx")

      ReqTest.stub(:tymeslot_http, fn _conn -> flunk("request must not leave the node") end)

      assert {:error, :network_error} = Client.call(config, "<m:FindFolder/>")

      logged = Enum.map_join(LogCapture.drain(), "\n", &LogCapture.dump/1)

      assert logged =~ "https://exchange.corp"
      refute logged =~ leak_canary()
      refute logged =~ "svc:"
    end
  end
end

defmodule ExchangeSsrfPrivateResolver do
  @moduledoc false
  @behaviour Tymeslot.Security.DnsResolutionBehaviour

  @impl Tymeslot.Security.DnsResolutionBehaviour
  def check_private_ip(_url, _opts),
    do: {:error, "URL resolves to a private or local network address"}
end
