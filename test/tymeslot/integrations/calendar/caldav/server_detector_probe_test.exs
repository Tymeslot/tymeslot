defmodule Tymeslot.Integrations.Calendar.CalDAV.ServerDetectorProbeTest do
  use ExUnit.Case, async: false
  @moduletag :integrations

  import Mox
  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Integrations.Calendar.CalDAV.ServerDetector

  setup :verify_on_exit!

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.HTTPClientMock)
    :ok
  end

  # These tests verify that the server probe (OPTIONS request) used when
  # URL-based detection returns :generic routes through HTTPClient so that
  # proxy configuration is respected.

  describe "auto_detect/3 server probe" do
    test "routes OPTIONS probe through HTTPClient when URL is unrecognised" do
      expect(Tymeslot.HTTPClientMock, :request, fn :options, url, "", _headers, _opts ->
        assert url == "https://mycalendar.example.com/"
        {:ok, %Req.Response{status: 200, body: "", headers: %{"server" => ["Radicale/3.0"]}}}
      end)

      # URL gives no hostname or path signal, so auto_detect falls through to probe
      assert {:ok, :radicale} =
               ServerDetector.auto_detect("https://mycalendar.example.com", "user", "pass")
    end

    test "returns :generic when probe headers carry no recognisable server" do
      expect(Tymeslot.HTTPClientMock, :request, fn :options, _url, "", _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "", headers: %{}}}
      end)

      assert {:ok, :generic} =
               ServerDetector.auto_detect("https://mycalendar.example.com", "user", "pass")
    end

    test "skips probe when URL is already recognisable" do
      # No HTTPClientMock expectation set — any call would fail verify_on_exit!
      assert {:ok, :nextcloud} =
               ServerDetector.auto_detect(
                 "https://cloud.example.com/remote.php/dav",
                 "user",
                 "pass"
               )
    end
  end
end
