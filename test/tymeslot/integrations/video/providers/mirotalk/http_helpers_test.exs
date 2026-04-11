defmodule Tymeslot.Integrations.Video.Providers.MiroTalk.HttpHelpersTest do
  use ExUnit.Case, async: true

  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Video.Providers.MiroTalk.HttpHelpers

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
        if String.starts_with?(url, "https://"), do: {:ok, resp}, else: flunk("unexpected fallback")
      end

      assert {:ok, ^resp} = HttpHelpers.try_https_then_http("http://example.com", "/api", fun)
    end

    test "falls back to original URL when HTTPS call raises a connection exception" do
      resp = %Req.Response{status: 200, body: "ok", headers: %{}}

      fun = fn url ->
        if String.starts_with?(url, "https://"),
          do: {:error, %Mint.TransportError{reason: :econnrefused}},
          else: {:ok, resp}
      end

      assert {:ok, ^resp} = HttpHelpers.try_https_then_http("http://example.com", "/api", fun)
    end

    test "returns error when HTTPS fails with an exception and fallback also fails with an exception" do
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
