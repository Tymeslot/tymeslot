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

  describe "request_budget_ms/2" do
    test "adds Req's default connect timeout to the method's default receive timeout" do
      assert HTTPClient.request_budget_ms(:get) == 60_000
      assert HTTPClient.request_budget_ms(:post) == 75_000
      assert HTTPClient.request_budget_ms(:report) == 90_000
    end

    test "uses the timeouts a request is sent with" do
      options = [receive_timeout: 15_000, connect_options: [timeout: 5_000]]

      assert HTTPClient.request_budget_ms(:post, options) == 20_000
    end

    test "honours the older timeout option, which takes precedence over the receive timeout" do
      assert HTTPClient.request_budget_ms(:post, timeout: 5_000, receive_timeout: 15_000) ==
               35_000
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
end
