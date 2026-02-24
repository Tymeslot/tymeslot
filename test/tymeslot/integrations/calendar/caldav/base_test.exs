defmodule Tymeslot.Integrations.Calendar.CalDAV.BaseTest do
  use ExUnit.Case, async: false
  @moduletag :integrations

  import Tymeslot.ConfigTestHelpers

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.CalDAV.Base

  # These tests exercise the real HTTPClient → Req → Req.Test path so that
  # transport-level bugs (method normalisation, header building, option assembly)
  # are caught automatically.  The global test config points :http_client_module
  # at HTTPClientMock; we override it here to use the real HTTPClient.

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    :ok
  end

  describe "propfind/4" do
    test "routes PROPFIND through HTTPClient" do
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
               Base.propfind("https://caldav.example.com/calendars/user/", "user", "pass")
    end

    test "returns :unauthorized on 401 response" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 401, "")
      end)

      assert {:error, :unauthorized} =
               Base.propfind("https://caldav.example.com/calendars/user/", "user", "bad_pass")
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
               Base.report(
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
               Base.report(
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
               Base.put_event(
                 "https://caldav.example.com/calendars/user/personal/event.ics",
                 "user",
                 "pass",
                 "BEGIN:VCALENDAR\nEND:VCALENDAR"
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
               Base.delete_event(
                 "https://caldav.example.com/calendars/user/personal/event.ics",
                 "user",
                 "pass"
               )
    end
  end

  describe "head_event/4" do
    test "routes HEAD through HTTPClient" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "HEAD"
        assert conn.request_path == "/calendars/user/personal/event.ics"

        conn
        |> Conn.put_resp_header("etag", "\"abc123\"")
        |> Conn.send_resp(200, "")
      end)

      assert {:ok, _response} =
               Base.head_event(
                 "https://caldav.example.com/calendars/user/personal/event.ics",
                 "user",
                 "pass"
               )
    end
  end
end
