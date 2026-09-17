defmodule Tymeslot.Infrastructure.HTTPClientTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Infrastructure.FinchPool
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
    # Only the part under test is left non-zero.
    @no_wait [pool_timeout: 0, connect_options: [timeout: 0], request_timeout: 0]

    test "adds the pool checkout, the connect and the response timeouts" do
      assert HTTPClient.request_budget_ms(:post,
               pool_timeout: 1_000,
               connect_options: [timeout: 2_000],
               request_timeout: 3_000
             ) == 6_000
    end

    test "waits for a pool checkout as long as Finch does by default" do
      assert HTTPClient.request_budget_ms(:post, Keyword.delete(@no_wait, :pool_timeout)) == 5_000
    end

    test "connects as long as the shared pool does unless the request says otherwise" do
      pool_connect =
        FinchPool.default_options()
        |> Keyword.fetch!(:conn_opts)
        |> get_in([:transport_opts, :timeout])

      assert HTTPClient.request_budget_ms(:post, Keyword.delete(@no_wait, :connect_options)) ==
               pool_connect
    end

    test "counts the receive timeout for the response when nothing caps the whole response" do
      unbounded = Keyword.delete(@no_wait, :request_timeout)

      assert HTTPClient.request_budget_ms(:post, unbounded ++ [receive_timeout: 7_000]) == 7_000
      assert HTTPClient.request_budget_ms(:get, unbounded) == 30_000
      assert HTTPClient.request_budget_ms(:post, unbounded ++ [timeout: 4_000]) == 4_000
    end

    test "counts the cap on the whole response when the request carries one" do
      assert HTTPClient.request_budget_ms(:post,
               pool_timeout: 0,
               connect_options: [timeout: 0],
               receive_timeout: 45_000,
               request_timeout: 15_000
             ) == 15_000
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
