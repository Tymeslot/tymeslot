defmodule Tymeslot.Integrations.Calendar.CalDAV.HttpTest do
  use Tymeslot.CalDAVCase, async: false
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalDAV.Http

  # These tests exercise the real HTTPClient → Req → Req.Test path so that
  # transport-level bugs (method normalisation, header building, option assembly)
  # are caught automatically. The global test config points :http_client_module
  # at HTTPClientMock; CalDAVCase overrides it to use the real HTTPClient.

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
end
