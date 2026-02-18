defmodule Tymeslot.Infrastructure.ProxyVerifierTest do
  use ExUnit.Case, async: false
  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.ProxyVerifier

  setup do
    # Save original proxy config
    original_proxy = Application.get_env(:tymeslot, :http_proxy)

    on_exit(fn ->
      if original_proxy do
        Application.put_env(:tymeslot, :http_proxy, original_proxy)
      else
        Application.delete_env(:tymeslot, :http_proxy)
      end
    end)

    :ok
  end

  describe "verify/1" do
    test "returns error when no proxy is configured" do
      Application.delete_env(:tymeslot, :http_proxy)

      result = ProxyVerifier.verify()

      assert result.proxy_configured == false
      assert result.proxy_reachable == false
      assert result.traffic_flows_through_proxy == false
      assert Enum.any?(result.errors, &String.contains?(&1, "No proxy configured"))
    end

    test "returns configured status when proxy is set" do
      Application.put_env(:tymeslot, :http_proxy, %{
        http_proxy: nil,
        https_proxy: %{
          host: "proxy.example.com",
          port: 8080,
          auth: nil,
          scheme: "http"
        },
        no_proxy: []
      })

      # This will attempt to connect to the proxy, which will fail in tests
      # but we can verify that it detected the configuration
      result = ProxyVerifier.verify()

      assert result.proxy_configured == true
      assert result.details.config != nil
    end

    test "reports error when test URL is in NO_PROXY list" do
      Application.put_env(:tymeslot, :http_proxy, %{
        http_proxy: nil,
        https_proxy: %{
          host: "proxy.example.com",
          port: 8080,
          auth: nil,
          scheme: "http"
        },
        no_proxy: ["httpbin.org", "*.httpbin.org"]
      })

      result = ProxyVerifier.verify()

      assert result.proxy_configured == true
      assert Enum.any?(result.errors, &String.contains?(&1, "cannot verify proxy"))
    end

    test "accepts custom test URL" do
      Application.put_env(:tymeslot, :http_proxy, %{
        http_proxy: nil,
        https_proxy: %{
          host: "proxy.example.com",
          port: 8080,
          auth: nil,
          scheme: "http"
        },
        no_proxy: []
      })

      result = ProxyVerifier.verify(test_url: "https://api.example.com/test")

      assert result.proxy_configured == true
      # Will fail to connect but that's expected in tests
      assert result.details[:test_url] == "https://api.example.com/test"
    end
  end

  describe "quick_check/0" do
    test "returns error when no proxy is configured" do
      Application.delete_env(:tymeslot, :http_proxy)

      assert {:error, "No proxy configured"} = ProxyVerifier.quick_check()
    end

    test "attempts connection when proxy is configured" do
      Application.put_env(:tymeslot, :http_proxy, %{
        http_proxy: nil,
        https_proxy: %{
          host: "proxy.example.com",
          port: 8080,
          auth: nil,
          scheme: "http"
        },
        no_proxy: []
      })

      # Will fail to connect in test environment, but that's expected
      result = ProxyVerifier.quick_check()

      assert match?({:error, _}, result)
    end
  end

  describe "input validation" do
    setup do
      # Configure a dummy proxy so validation is the only thing being tested
      Application.put_env(:tymeslot, :http_proxy, %{
        http_proxy: nil,
        https_proxy: %{
          host: "proxy.example.com",
          port: 8080,
          auth: nil,
          scheme: "http"
        },
        no_proxy: []
      })

      :ok
    end

    test "rejects HTTP URLs (must be HTTPS)" do
      assert_raise ArgumentError, ~r/must use HTTPS/i, fn ->
        ProxyVerifier.verify(test_url: "http://example.com")
      end
    end

    test "rejects URLs without scheme" do
      assert_raise ArgumentError, ~r/must include a scheme/i, fn ->
        ProxyVerifier.verify(test_url: "example.com/path")
      end
    end

    test "rejects malformed URLs" do
      assert_raise ArgumentError, ~r/must include a scheme/i, fn ->
        ProxyVerifier.verify(test_url: "not-a-valid-url")
      end
    end

    test "rejects URLs without hostname" do
      assert_raise ArgumentError, ~r/Invalid test URL format/i, fn ->
        ProxyVerifier.verify(test_url: "https://")
      end
    end

    test "rejects non-string URLs" do
      assert_raise ArgumentError, ~r/must be a string/i, fn ->
        ProxyVerifier.verify(test_url: :invalid)
      end
    end

    test "accepts valid HTTPS URLs" do
      # Should not raise, will fail to connect but that's expected in tests
      result = ProxyVerifier.verify(test_url: "https://valid.example.com/path")
      assert is_map(result)
    end

    test "rejects timeout below minimum (1000ms)" do
      assert_raise ArgumentError, ~r/Timeout too short.*minimum: 1000ms/i, fn ->
        ProxyVerifier.verify(timeout: 999)
      end
    end

    test "rejects timeout above maximum (300000ms)" do
      assert_raise ArgumentError, ~r/Timeout too long.*maximum: 300000ms/i, fn ->
        ProxyVerifier.verify(timeout: 300_001)
      end
    end

    test "rejects negative timeout" do
      assert_raise ArgumentError, ~r/Timeout too short/i, fn ->
        ProxyVerifier.verify(timeout: -1)
      end
    end

    test "rejects non-integer timeout" do
      assert_raise ArgumentError, ~r/must be an integer/i, fn ->
        ProxyVerifier.verify(timeout: "5000")
      end
    end

    test "accepts valid timeout at minimum boundary" do
      result = ProxyVerifier.verify(timeout: 1_000)
      assert is_map(result)
    end

    test "accepts valid timeout at maximum boundary" do
      result = ProxyVerifier.verify(timeout: 300_000)
      assert is_map(result)
    end

    test "accepts valid timeout in normal range" do
      result = ProxyVerifier.verify(timeout: 10_000)
      assert is_map(result)
    end
  end
end
