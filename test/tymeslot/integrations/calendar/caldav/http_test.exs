defmodule Tymeslot.Integrations.Calendar.CalDAV.HttpTest do
  use Tymeslot.HttpTransportCase, async: false
  @moduletag :integrations

  import ExUnit.CaptureLog

  alias Tymeslot.Integrations.Calendar.CalDAV.Http
  alias Tymeslot.Test.LogCapture

  # These tests exercise the real HTTPClient → Req → Req.Test path so that
  # transport-level bugs (method normalisation, header building, option assembly)
  # are caught automatically. The global test config points :http_client_module
  # at HTTPClientMock; HttpTransportCase overrides it to use the real HTTPClient.

  describe "propfind/4" do
    test "routes PROPFIND through HTTPClient with Basic auth header" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "PROPFIND"
        assert conn.request_path == "/calendars/user/"

        [auth | _rest] = Conn.get_req_header(conn, "authorization")
        assert String.starts_with?(auth, "Basic ")

        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, "<xml/>")
      end)

      assert {:ok, %Req.Response{status: 207}} =
               Http.propfind("https://caldav.example.com/calendars/user/", "user", "pass")
    end

    test "maps 401 to :unauthorized" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 401, "")
      end)

      assert {:error, :unauthorized} =
               Http.propfind(
                 "https://caldav.example.com/calendars/user/",
                 "user",
                 "bad_pass",
                 max_retries: 0
               )
    end

    test "maps 403 to :forbidden (resource access denied, distinct from auth failure)" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 403, "")
      end)

      assert {:error, :forbidden} =
               Http.propfind(
                 "https://caldav.example.com/calendars/user/",
                 "user",
                 "bad_pass",
                 max_retries: 0
               )
    end

    test "maps transport timeout to :timeout" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        ReqTest.transport_error(conn, :timeout)
      end)

      assert {:error, :timeout} =
               Http.propfind(
                 "https://caldav.example.com/calendars/user/",
                 "user",
                 "pass",
                 max_retries: 0
               )
    end

    test "maps network error to :network_error" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        ReqTest.transport_error(conn, :econnrefused)
      end)

      assert {:error, :network_error} =
               Http.propfind(
                 "https://caldav.example.com/calendars/user/",
                 "user",
                 "pass",
                 max_retries: 0
               )
    end
  end

  describe "report/5" do
    test "routes REPORT through HTTPClient" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "REPORT"
        assert conn.request_path == "/calendars/user/personal/"

        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, "<xml/>")
      end)

      assert {:ok, %Req.Response{status: 207}} =
               Http.report(
                 "https://caldav.example.com/calendars/user/personal/",
                 "user",
                 "pass",
                 "<calendar-query/>"
               )
    end

    test "maps transport timeout to :timeout" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        ReqTest.transport_error(conn, :timeout)
      end)

      assert {:error, :timeout} =
               Http.report(
                 "https://caldav.example.com/calendars/user/personal/",
                 "user",
                 "pass",
                 "<calendar-query/>"
               )
    end

    test "maps 403 to :forbidden (resource access denied, distinct from auth failure)" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 403, "")
      end)

      assert {:error, :forbidden} =
               Http.report(
                 "https://caldav.example.com/calendars/user/personal/",
                 "user",
                 "bad_pass",
                 "<calendar-query/>"
               )
    end

    test "maps 5xx to :server_error" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      assert {:error, :server_error} =
               Http.report(
                 "https://caldav.example.com/calendars/user/personal/",
                 "user",
                 "pass",
                 "<calendar-query/>"
               )
    end

    test "maps an unmodelled status to {:unexpected_status, status}" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 415, "Unsupported Media Type")
      end)

      assert {:error, {:unexpected_status, 415}} =
               Http.report(
                 "https://caldav.example.com/calendars/user/personal/",
                 "user",
                 "pass",
                 "<calendar-query/>"
               )
    end

    test "logs the server's explanation for an unmodelled status" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 415, "<error>only text/xml is supported here</error>")
      end)

      # Production logs the metadata (JSON, `:all_except`), so the excerpt is
      # asserted where it actually lands rather than in the message.
      log =
        capture_log([format: "$message $metadata\n", metadata: [:status, :body]], fn ->
          assert {:error, {:unexpected_status, 415}} =
                   Http.report(
                     "https://caldav.example.com/calendars/user/personal/",
                     "user",
                     "pass",
                     "<calendar-query/>"
                   )
        end)

      assert log =~ "only text/xml is supported here"
      assert log =~ "status=415"
    end

    test "sends Depth: 1 by default and the caller's value when given" do
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        send(test_pid, {:depth, Conn.get_req_header(conn, "depth")})

        conn
        |> Conn.put_resp_header("content-type", "application/xml")
        |> Conn.send_resp(207, "<xml/>")
      end)

      url = "https://caldav.example.com/calendars/user/personal/"

      assert {:ok, _default} = Http.report(url, "user", "pass", "<calendar-query/>")
      assert_received {:depth, ["1"]}

      assert {:ok, _depth_0} = Http.report(url, "user", "pass", "<sync-collection/>", depth: "0")
      assert_received {:depth, ["0"]}
    end

    test "applies a caller's status override before the shared status table" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 410, "Gone")
      end)

      url = "https://caldav.example.com/calendars/user/personal/"

      assert {:error, :sync_token_expired} =
               Http.report(url, "user", "pass", "<sync-collection/>",
                 status_overrides: %{410 => :sync_token_expired}
               )

      # Without the override the same status stays unmodelled: a calendar-query
      # answered with 410 says nothing about a sync token.
      assert {:error, {:unexpected_status, 410}} =
               Http.report(url, "user", "pass", "<calendar-query/>")
    end
  end

  describe "put_event/5" do
    test "routes PUT through HTTPClient" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/calendars/user/personal/event.ics"

        Conn.send_resp(conn, 201, "")
      end)

      assert {:ok, _response} =
               Http.put_event(
                 "https://caldav.example.com/calendars/user/personal/event.ics",
                 "user",
                 "pass",
                 "BEGIN:VCALENDAR\nEND:VCALENDAR"
               )
    end

    test "adds If-None-Match: * for :create operation" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert Conn.get_req_header(conn, "if-none-match") == ["*"]
        Conn.send_resp(conn, 201, "")
      end)

      assert {:ok, _response} =
               Http.put_event(
                 "https://caldav.example.com/calendars/user/personal/event.ics",
                 "user",
                 "pass",
                 "BEGIN:VCALENDAR\nEND:VCALENDAR",
                 operation: :create
               )
    end

    test "adds If-Match with etag for :update operation" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert Conn.get_req_header(conn, "if-match") == ["\"etag-123\""]
        Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, _response} =
               Http.put_event(
                 "https://caldav.example.com/calendars/user/personal/event.ics",
                 "user",
                 "pass",
                 "BEGIN:VCALENDAR\nEND:VCALENDAR",
                 operation: :update,
                 if_match: "\"etag-123\""
               )
    end

    test "adds If-Match: * for :update without etag" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert Conn.get_req_header(conn, "if-match") == ["*"]
        Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, _response} =
               Http.put_event(
                 "https://caldav.example.com/calendars/user/personal/event.ics",
                 "user",
                 "pass",
                 "BEGIN:VCALENDAR\nEND:VCALENDAR",
                 operation: :update
               )
    end

    test "sends no conditional header for :force_update operation" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert Conn.get_req_header(conn, "if-match") == []
        assert Conn.get_req_header(conn, "if-none-match") == []
        Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, _response} =
               Http.put_event(
                 "https://caldav.example.com/calendars/user/personal/event.ics",
                 "user",
                 "pass",
                 "BEGIN:VCALENDAR\nEND:VCALENDAR",
                 operation: :force_update
               )
    end

    test "maps 409 Conflict to :conditional_not_supported atom" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 409, "Conflict")
      end)

      assert {:error, :conditional_not_supported} =
               Http.put_event(
                 "https://caldav.example.com/calendars/user/personal/event.ics",
                 "user",
                 "pass",
                 "BEGIN:VCALENDAR\nEND:VCALENDAR",
                 operation: :update
               )
    end

    test "maps 412 Precondition Failed to :precondition_failed atom" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 412, "Precondition Failed")
      end)

      assert {:error, :precondition_failed} =
               Http.put_event(
                 "https://caldav.example.com/calendars/user/personal/event.ics",
                 "user",
                 "pass",
                 "BEGIN:VCALENDAR\nEND:VCALENDAR",
                 operation: :create
               )
    end
  end

  describe "delete_event/4" do
    test "routes DELETE through HTTPClient" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/calendars/user/personal/event.ics"

        Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, _response} =
               Http.delete_event(
                 "https://caldav.example.com/calendars/user/personal/event.ics",
                 "user",
                 "pass"
               )
    end

    test "tolerates 404 — delete is idempotent" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 404, "")
      end)

      assert {:ok, _response} =
               Http.delete_event(
                 "https://caldav.example.com/calendars/user/personal/gone.ics",
                 "user",
                 "pass"
               )
    end

    test "maps 401 to :unauthorized" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 401, "")
      end)

      assert {:error, :unauthorized} =
               Http.delete_event(
                 "https://caldav.example.com/calendars/user/personal/event.ics",
                 "user",
                 "bad_pass"
               )
    end
  end

  describe "head_event/4" do
    test "routes HEAD through HTTPClient and returns ETag header" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "HEAD"
        assert conn.request_path == "/calendars/user/personal/event.ics"

        conn
        |> Conn.put_resp_header("etag", "\"abc123\"")
        |> Conn.send_resp(200, "")
      end)

      assert {:ok, %Req.Response{headers: %{"etag" => ["\"abc123\""]}}} =
               Http.head_event(
                 "https://caldav.example.com/calendars/user/personal/event.ics",
                 "user",
                 "pass"
               )
    end

    test "maps 404 to :not_found" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 404, "")
      end)

      assert {:error, :not_found} =
               Http.head_event(
                 "https://caldav.example.com/calendars/user/personal/missing.ics",
                 "user",
                 "pass"
               )
    end

    test "maps 401 to :unauthorized" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 401, "")
      end)

      assert {:error, :unauthorized} =
               Http.head_event(
                 "https://caldav.example.com/calendars/user/personal/event.ics",
                 "user",
                 "bad_pass"
               )
    end

    test "maps 5xx to :server_error" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 503, "")
      end)

      assert {:error, :server_error} =
               Http.head_event(
                 "https://caldav.example.com/calendars/user/personal/event.ics",
                 "user",
                 "pass"
               )
    end
  end

  # Baikal ships `dav_auth_type: Digest` by default and SabreDAV refuses a Basic
  # header outright in that mode, so a Basic-only client cannot reach a stock
  # install however correct its credentials are. Every CalDAV method shares one
  # challenge-and-retry path, so these exercise it through the methods whose
  # extra headers differ most.
  describe "digest authentication" do
    @digest_challenge ~s(Digest realm="BaikalDAV", qop="auth", ) <>
                        ~s(nonce="6aa0f27df2c20", opaque="d66d5f0524036afcb61420e358f990ce")

    defp challenge_then(second) do
      stub_sequential(
        fn conn ->
          conn
          |> Conn.put_resp_header("www-authenticate", @digest_challenge)
          |> Conn.send_resp(401, "")
        end,
        second
      )
    end

    test "retries a challenged PROPFIND with a Digest header and returns the second answer" do
      test_pid = self()

      challenge_then(fn conn ->
        [auth | _rest] = Conn.get_req_header(conn, "authorization")
        send(test_pid, {:retry_authorization, auth})

        Conn.send_resp(conn, 207, "<xml/>")
      end)

      assert {:ok, %Req.Response{status: 207}} =
               Http.propfind(
                 "https://caldav.example.com/dav.php/calendars/user/",
                 "user",
                 "pass",
                 max_retries: 0
               )

      assert_received {:retry_authorization, authorization}
      assert String.starts_with?(authorization, "Digest ")
      assert authorization =~ ~s(username="user")
      assert authorization =~ ~s(realm="BaikalDAV")
      assert authorization =~ ~s(nonce="6aa0f27df2c20")
      assert authorization =~ ~s(opaque="d66d5f0524036afcb61420e358f990ce")
      # The digest covers the request target and method, so both must be the
      # ones actually being retried.
      assert authorization =~ ~s(uri="/dav.php/calendars/user/")
    end

    test "keeps the conditional header on a challenged PUT's retry" do
      test_pid = self()

      challenge_then(fn conn ->
        send(
          test_pid,
          {:retry_headers, Conn.get_req_header(conn, "if-none-match"),
           Conn.get_req_header(conn, "authorization")}
        )

        Conn.send_resp(conn, 201, "")
      end)

      assert {:ok, %Req.Response{status: 201}} =
               Http.put_event(
                 "https://caldav.example.com/dav.php/calendars/user/personal/event.ics",
                 "user",
                 "pass",
                 "BEGIN:VCALENDAR\nEND:VCALENDAR",
                 operation: :create
               )

      assert_received {:retry_headers, ["*"], [authorization]}
      assert String.starts_with?(authorization, "Digest ")
    end

    test "surfaces a second 401 as :unauthorized rather than retrying forever" do
      call_count = :counters.new(1, [:atomics])

      ReqTest.stub(:tymeslot_http, fn conn ->
        :counters.add(call_count, 1, 1)

        conn
        |> Conn.put_resp_header("www-authenticate", @digest_challenge)
        |> Conn.send_resp(401, "")
      end)

      assert {:error, :unauthorized} =
               Http.propfind(
                 "https://caldav.example.com/dav.php/calendars/user/",
                 "user",
                 "wrong_pass",
                 max_retries: 0
               )

      assert :counters.get(call_count, 1) == 2
    end

    test "does not retry a 401 that carries no Digest challenge" do
      call_count = :counters.new(1, [:atomics])

      ReqTest.stub(:tymeslot_http, fn conn ->
        :counters.add(call_count, 1, 1)

        conn
        |> Conn.put_resp_header("www-authenticate", ~s(Basic realm="CalDAV"))
        |> Conn.send_resp(401, "")
      end)

      assert {:error, :unauthorized} =
               Http.propfind(
                 "https://caldav.example.com/calendars/user/",
                 "user",
                 "bad_pass",
                 max_retries: 0
               )

      assert :counters.get(call_count, 1) == 1
    end

    test "logs the unanswerable parameter when the challenge names one it cannot compute" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        conn
        |> Conn.put_resp_header(
          "www-authenticate",
          ~s(Digest realm="CalDAV", qop="auth-int", nonce="abc123")
        )
        |> Conn.send_resp(401, "")
      end)

      LogCapture.attach()

      assert {:error, :unauthorized} =
               Http.propfind(
                 "https://caldav.example.com/calendars/user/",
                 "user",
                 "pass",
                 max_retries: 0
               )

      # The account owner only ever sees the generic credentials message, so
      # the parameter the server insisted on has to reach the operator here.
      assert_receive {:captured_log, %{level: :warning, meta: %{detail: detail}} = event}
      assert detail == "qop=auth-int"
      assert event.meta.method == "PROPFIND"
    end
  end
end
