defmodule Tymeslot.Infrastructure.HTTPClientTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Infrastructure.HTTPClient

  setup do
    ReqTest.stub(:tymeslot_http, fn conn ->
      Conn.send_resp(conn, 200, "ok")
    end)

    :ok
  end

  describe "request/5 method normalization" do
    test "accepts known string methods and converts to atoms" do
      assert {:ok, %Req.Response{status: 200}} =
               HTTPClient.request("GET", "http://localhost/test")

      assert {:ok, %Req.Response{status: 200}} =
               HTTPClient.request("post", "http://localhost/test")
    end

    test "passes non-standard CalDAV methods as uppercase strings to Req" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method in ["PROPFIND", "REPORT"]
        Conn.send_resp(conn, 207, "<xml/>")
      end)

      for method <- [:propfind, :report] do
        assert {:ok, %Req.Response{status: 207}} =
                 HTTPClient.request(method, "http://localhost/cal")
      end
    end

    test "rejects unknown methods without creating atoms" do
      unknown_method = "UNKNOWN_VERB_#{:erlang.unique_integer()}"

      assert {:error, %RuntimeError{message: message}} =
               HTTPClient.request(unknown_method, "http://example.com")

      assert message =~ "Invalid HTTP method"

      # Verify atom was not created
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_method) end
    end
  end

  describe "retry behaviour" do
    test "does not retry failed GET requests" do
      call_count = :counters.new(1, [:atomics])

      ReqTest.stub(:tymeslot_http, fn conn ->
        :counters.add(call_count, 1, 1)
        Conn.send_resp(conn, 503, "unavailable")
      end)

      assert {:ok, %Req.Response{status: 503}} =
               HTTPClient.get("http://localhost/test")

      assert :counters.get(call_count, 1) == 1
    end
  end

  describe "connect timeout" do
    test "proxy connect_options include a 10s connect timeout" do
      proxy_config = %{
        scheme: "http",
        host: "proxy.example.com",
        port: 8080,
        auth: nil
      }

      opts = Tymeslot.Infrastructure.ProxyConfig.build_req_proxy_options(proxy_config)
      connect_options = Keyword.get(opts, :connect_options, [])
      assert Keyword.get(connect_options, :timeout) == 10_000
    end
  end
end
