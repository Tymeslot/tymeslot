defmodule Tymeslot.Integrations.Calendar.CalDAV.BaseTest do
  use ExUnit.Case, async: false
  @moduletag :integrations

  import Mox
  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Integrations.Calendar.CalDAV.Base

  setup :verify_on_exit!

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.HTTPClientMock)
    :ok
  end

  # These tests exist to verify that CalDAV operations route through HTTPClient
  # rather than calling Finch directly. Routing through HTTPClient is what makes
  # proxy configuration (HTTP_PROXY / HTTPS_PROXY / NO_PROXY) take effect.

  describe "propfind/4" do
    test "routes PROPFIND through HTTPClient" do
      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, url, _body, headers, opts ->
        assert url == "https://caldav.example.com/calendars/user/"

        assert Enum.any?(headers, fn {k, _v} ->
                 String.downcase(k) == "authorization"
               end)

        assert opts[:receive_timeout] != nil

        {:ok, %Req.Response{status: 207, body: "<xml/>"}}
      end)

      assert {:ok, %Req.Response{status: 207}} =
               Base.propfind("https://caldav.example.com/calendars/user/", "user", "pass")
    end

    test "returns :unauthorized on 401 response" do
      expect(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: ""}}
      end)

      assert {:error, :unauthorized} =
               Base.propfind("https://caldav.example.com/calendars/user/", "user", "bad_pass")
    end
  end

  describe "report/5" do
    test "routes REPORT through HTTPClient" do
      expect(Tymeslot.HTTPClientMock, :request, fn :report, url, body, _headers, _opts ->
        assert url == "https://caldav.example.com/calendars/user/personal/"
        assert is_binary(body)
        {:ok, %Req.Response{status: 207, body: "<xml/>"}}
      end)

      assert {:ok, %Req.Response{status: 207}} =
               Base.report(
                 "https://caldav.example.com/calendars/user/personal/",
                 "user",
                 "pass",
                 "<calendar-query/>"
               )
    end

    test "maps Mint.TransportError timeout to :timeout" do
      expect(Tymeslot.HTTPClientMock, :request, fn :report, _url, _body, _headers, _opts ->
        {:error, %Mint.TransportError{reason: :timeout}}
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
      expect(Tymeslot.HTTPClientMock, :put, fn url, body, _headers, _opts ->
        assert url == "https://caldav.example.com/calendars/user/personal/event.ics"
        assert is_binary(body)
        {:ok, %Req.Response{status: 201, body: ""}}
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
      expect(Tymeslot.HTTPClientMock, :delete, fn url, _headers, _opts ->
        assert url == "https://caldav.example.com/calendars/user/personal/event.ics"
        {:ok, %Req.Response{status: 204, body: ""}}
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
      expect(Tymeslot.HTTPClientMock, :head, fn url, _headers, _opts ->
        assert url == "https://caldav.example.com/calendars/user/personal/event.ics"
        {:ok, %Req.Response{status: 200, body: "", headers: %{"etag" => ["\"abc123\""]}}}
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
