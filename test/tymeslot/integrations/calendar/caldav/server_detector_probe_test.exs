defmodule Tymeslot.Integrations.Calendar.CalDAV.ServerDetectorProbeTest do
  use ExUnit.Case, async: false
  @moduletag :integrations

  import Tymeslot.ConfigTestHelpers

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.CalDAV.ServerDetector

  # These tests verify that the server probe (OPTIONS request) used when
  # URL-based detection returns :generic routes through HTTPClient so that
  # proxy configuration is respected.  The global test config points
  # :http_client_module at HTTPClientMock; we override it here to use the
  # real HTTPClient so the full Req stack is exercised.

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    :ok
  end

  describe "auto_detect/3 server probe" do
    test "routes OPTIONS probe through HTTPClient when URL is unrecognised" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "OPTIONS"
        assert conn.host == "mycalendar.example.com"

        conn
        |> Conn.put_resp_header("server", "Radicale/3.0")
        |> Conn.send_resp(200, "")
      end)

      assert {:ok, :radicale} =
               ServerDetector.auto_detect("https://mycalendar.example.com", "user", "pass")
    end

    test "returns :generic when probe headers carry no recognisable server" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        Conn.send_resp(conn, 200, "")
      end)

      assert {:ok, :generic} =
               ServerDetector.auto_detect("https://mycalendar.example.com", "user", "pass")
    end

    test "skips probe when URL is already recognisable" do
      # No stub registered — if an HTTP call were accidentally made, Req.Test
      # would raise, catching the regression.
      assert {:ok, :nextcloud} =
               ServerDetector.auto_detect(
                 "https://cloud.example.com/remote.php/dav",
                 "user",
                 "pass"
               )
    end
  end
end
