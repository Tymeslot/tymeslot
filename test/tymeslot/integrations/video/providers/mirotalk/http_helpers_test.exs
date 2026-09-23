defmodule Tymeslot.Integrations.Video.Providers.MiroTalk.HttpHelpersTest do
  # async: false — the cleartext-retry tests move the global private-address
  # switches, which every concurrently running test would otherwise see.
  use ExUnit.Case, async: false

  @moduletag :integrations
  @moduletag :unit

  import Tymeslot.ConfigTestHelpers, only: [with_config: 3]

  alias Tymeslot.Integrations.Video.Providers.MiroTalk.HttpHelpers

  setup do
    with_config(:tymeslot, :allow_private_ips_for_calendar, false)
    # `nil` is the unset switch, as `config/runtime.exs` leaves it.
    with_config(:tymeslot, :allow_private_ips_for_video, nil)
    :ok
  end

  describe "force_https/1" do
    test "rewrites an HTTP URL to HTTPS" do
      assert HttpHelpers.force_https("http://mirotalk.example.com") ==
               "https://mirotalk.example.com"
    end

    test "strips a non-standard port when rewriting to HTTPS" do
      result = HttpHelpers.force_https("http://mirotalk.example.com:3000")
      assert result == "https://mirotalk.example.com"
      refute result =~ ":3000"
    end

    test "normalises an already-HTTPS URL with a non-standard port" do
      result = HttpHelpers.force_https("https://mirotalk.example.com:8443")
      assert result == "https://mirotalk.example.com"
      refute result =~ ":8443"
    end

    test "preserves path and query string while forcing HTTPS" do
      result = HttpHelpers.force_https("http://mirotalk.example.com:3000/api?token=abc")
      assert result == "https://mirotalk.example.com/api?token=abc"
    end
  end

  describe "try_https_then_http/3 when base_url and path are binaries" do
    test "returns ok when the HTTPS call succeeds" do
      resp = %Req.Response{status: 200, body: "ok", headers: %{}}

      fun = fn url ->
        if String.starts_with?(url, "https://"),
          do: {:ok, resp},
          else: flunk("unexpected fallback")
      end

      assert {:ok, ^resp} = HttpHelpers.try_https_then_http("http://example.com", "/api", fun)
    end

    test "retries on the base URL's scheme when private addresses are allowed for video" do
      with_config(:tymeslot, :allow_private_ips_for_video, true)
      resp = %Req.Response{status: 200, body: "ok", headers: %{}}

      fun = fn url ->
        if String.starts_with?(url, "https://"),
          do: {:error, %Mint.TransportError{reason: :econnrefused}},
          else: {:ok, resp}
      end

      assert {:ok, ^resp} = HttpHelpers.try_https_then_http("http://example.com", "/api", fun)
    end

    test "returns the retry's error when both schemes fail and the retry was allowed" do
      with_config(:tymeslot, :allow_private_ips_for_video, true)
      https_err = %Mint.TransportError{reason: :econnrefused}
      http_err = %Mint.TransportError{reason: :timeout}

      fun = fn url ->
        if String.starts_with?(url, "https://"),
          do: {:error, https_err},
          else: {:error, http_err}
      end

      assert {:error, ^http_err} =
               HttpHelpers.try_https_then_http("http://example.com", "/api", fun)
    end

    test "returns error immediately for non-exception errors without falling back to HTTP" do
      calls = :counters.new(1, [:atomics])

      fun = fn _url ->
        :counters.add(calls, 1, 1)
        {:error, :unauthorized}
      end

      assert {:error, :unauthorized} =
               HttpHelpers.try_https_then_http("http://example.com", "/api", fun)

      assert :counters.get(calls, 1) == 1
    end

    test "does not retry in the clear when private addresses are not allowed for video" do
      https_err = %Mint.TransportError{reason: :econnrefused}
      calls = :counters.new(1, [:atomics])

      fun = fn url ->
        :counters.add(calls, 1, 1)

        if String.starts_with?(url, "https://"),
          do: {:error, https_err},
          else: flunk("retried over #{url}, which would send the API key in the clear")
      end

      assert {:error, ^https_err} =
               HttpHelpers.try_https_then_http("http://example.com", "/api", fun)

      assert :counters.get(calls, 1) == 1
    end

    test "the calendar switch alone still permits the retry, as it shipped covering video" do
      with_config(:tymeslot, :allow_private_ips_for_calendar, true)
      resp = %Req.Response{status: 200, body: "ok", headers: %{}}

      fun = fn url ->
        if String.starts_with?(url, "https://"),
          do: {:error, %Mint.TransportError{reason: :econnrefused}},
          else: {:ok, resp}
      end

      assert {:ok, ^resp} = HttpHelpers.try_https_then_http("http://example.com", "/api", fun)
    end

    test "appends path to the URL" do
      resp = %Req.Response{status: 200, body: "", headers: %{}}

      fun = fn url ->
        assert String.ends_with?(url, "/join")
        {:ok, resp}
      end

      HttpHelpers.try_https_then_http("https://example.com", "/join", fun)
    end
  end
end
